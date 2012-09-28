{-# LANGUAGE BangPatterns    #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections   #-}
-- |
-- Copyright   : (c) 2010-2012 Simon Meier & Benedikt Schmidt
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : GHC only
--
-- Types to represent proofs.
module Theory.Proof (
  -- * Utilities
    LTree(..)
  , mergeMapsWith

  -- * Types
  , ProofStep(..)
  , Proof

  -- ** Paths inside proofs
  , ProofPath
  , atPath
  , insertPaths

  -- ** Folding/modifying proofs
  , mapProofInfo
  , foldProof
  , annotateProof
  , ProofStatus(..)
  , proofStepStatus

  -- ** Unfinished proofs
  , sorry
  , unproven

  -- ** Incremental proof construction
  , IncrementalProof
  , Prover
  , runProver
  , mapProverProof

  , orelse
  , tryProver
  , sorryProver
  , oneStepProver
  , focus
  , checkAndExtendProver
  , replaceSorryProver
  , contradictionProver

  -- ** Explicit representation of a fully automatic prover
  , SolutionExtractor(..)
  , AutoProver(..)
  , runAutoProver

  -- ** Pretty Printing
  , prettyProof
  , prettyProofWith

  , showProofStatus

  -- ** Parallel Strategy for exploring a proof
  , parLTreeDFS

  -- ** Small-step interface to the constraint solver
  , module Theory.Constraint.Solver

) where

import           Data.Binary
import           Data.DeriveTH
import           Data.Foldable                    (Foldable, foldMap)
import           Data.List
import qualified Data.Map                         as M
import           Data.Maybe
import           Data.Monoid
import           Data.Traversable

import           Debug.Trace

import           Control.Basics
import           Control.DeepSeq
import qualified Control.Monad.State              as S
import           Control.Parallel.Strategies

import           Theory.Constraint.Solver
import           Theory.Model
import           Theory.Text.Pretty


------------------------------------------------------------------------------
-- Utility: Trees with uniquely labelled edges.
------------------------------------------------------------------------------

-- | Trees with uniquely labelled edges.
data LTree l a = LNode
     { root     :: a
     , children :: M.Map l (LTree l a)
     }
     deriving( Eq, Ord, Show )

instance Functor (LTree l) where
    fmap f (LNode r cs) = LNode (f r) (M.map (fmap f) cs)

instance Foldable (LTree l) where
    foldMap f (LNode x cs) = f x `mappend` foldMap (foldMap f) cs

instance Traversable (LTree l) where
    traverse f (LNode x cs) = LNode <$> f x <*> traverse (traverse f) cs

-- | A parallel evaluation strategy well-suited for DFS traversal: As soon as
-- a node is forced it sparks off the computation of the number of case-maps
-- of all its children. This way most of the data is already evaulated, when
-- the actual DFS traversal visits it.
--
-- NOT used for now. It sometimes required too much memory.
parLTreeDFS :: Strategy (LTree l a)
parLTreeDFS (LNode x0 cs0) = do
    cs0' <- (`parTraversable` cs0) $ \(LNode x cs) -> LNode x <$> rseq cs
    return $ LNode x0 (M.map (runEval . parLTreeDFS) cs0')

------------------------------------------------------------------------------
-- Utility: Merging maps
------------------------------------------------------------------------------

-- | /O(n+m)/. A generalized union operator for maps with differing types.
mergeMapsWith :: Ord k
              => (a -> c) -> (b -> c) -> (a -> b -> c)
              -> M.Map k a -> M.Map k b -> M.Map k c
mergeMapsWith leftOnly rightOnly combine l r =
    M.map extract $ M.unionWith combine' l' r'
  where
    l' = M.map (Left . Left)  l
    r' = M.map (Left . Right) r

    combine' (Left (Left a)) (Left (Right b)) = Right $ combine a b
    combine' _ _ = error "mergeMapsWith: impossible"

    extract (Left (Left  a)) = leftOnly  a
    extract (Left (Right b)) = rightOnly b
    extract (Right c)        = c


------------------------------------------------------------------------------
-- Proof Steps
------------------------------------------------------------------------------

-- | A proof steps is a proof method together with additional context-dependent
-- information.
data ProofStep a = ProofStep
     { psMethod :: ProofMethod
     , psInfo   :: a
     }
     deriving( Eq, Ord, Show )

instance Functor ProofStep where
    fmap f (ProofStep m i) = ProofStep m (f i)

instance Foldable ProofStep where
    foldMap f = f . psInfo

instance Traversable ProofStep where
    traverse f (ProofStep m i) = ProofStep m <$> f i

instance HasFrees a => HasFrees (ProofStep a) where
    foldFrees f (ProofStep m i) = foldFrees f m `mappend` foldFrees f i
    mapFrees f (ProofStep m i)  = ProofStep <$> mapFrees f m <*> mapFrees f i

------------------------------------------------------------------------------
-- Proof Trees
------------------------------------------------------------------------------

-- | A path to a subproof.
type ProofPath = [CaseName]

-- | A proof is a tree of proof steps whose edges are labelled with case names.
type Proof a = LTree CaseName (ProofStep a)

-- Unfinished proofs
--------------------

-- | A proof using the 'sorry' proof method.
sorry :: Maybe String -> a -> Proof a
sorry reason ann = LNode (ProofStep (Sorry reason) ann) M.empty

-- | A proof denoting an unproven part of the proof.
unproven :: a -> Proof a
unproven = sorry Nothing


-- Paths in proofs
------------------

-- | @prf `atPath` path@ returns the subproof at the @path@ in @prf@.
atPath :: Proof a -> ProofPath -> Maybe (Proof a)
atPath = foldM (flip M.lookup . children)

-- | @modifyAtPath f path prf@ applies @f@ to the subproof at @path@,
-- if there is one.
modifyAtPath :: (Proof a -> Maybe (Proof a)) -> ProofPath
             -> Proof a -> Maybe (Proof a)
modifyAtPath f =
    go
  where
    go []     prf = f prf
    go (l:ls) prf = do
        let cs = children prf
        prf' <- go ls =<< M.lookup l cs
        return (prf { children = M.insert l prf' cs })

-- | @insertPaths prf@ inserts the path to every proof node.
insertPaths :: Proof a -> Proof (a, ProofPath)
insertPaths =
    insertPath []
  where
    insertPath path (LNode ps cs) =
        LNode (fmap (,reverse path) ps)
              (M.mapWithKey (\n prf -> insertPath (n:path) prf) cs)


-- Utilities for dealing with proofs
------------------------------------


-- | Apply a function to the information of every proof step.
mapProofInfo :: (a -> b) -> Proof a -> Proof b
mapProofInfo = fmap . fmap

-- | @boundProofDepth bound prf@ bounds the depth of the proof @prf@ using
-- 'Sorry' steps to replace the cut sub-proofs.
boundProofDepth :: Int -> Proof a -> Proof a
boundProofDepth bound =
    go bound
  where
    go n (LNode ps@(ProofStep _ info) cs)
      | 0 < n     = LNode ps                     $ M.map (go (pred n)) cs
      | otherwise = sorry (Just $ "bound " ++ show bound ++ " hit") info

-- | Fold a proof.
foldProof :: Monoid m => (ProofStep a -> m) -> Proof a -> m
foldProof f =
    go
  where
    go (LNode step cs) = f step `mappend` foldMap go (M.elems cs)

-- | Annotate a proof in a bottom-up fashion.
annotateProof :: (ProofStep a -> [b] -> b) -> Proof a -> Proof b
annotateProof f =
    go
  where
    go (LNode step@(ProofStep method _) cs) =
        LNode (ProofStep method info') cs'
      where
        cs' = M.map go cs
        info' = f step (map (psInfo . root . snd) (M.toList cs'))

-- Proof cutting
----------------

-- | The status of a 'Proof'.
data ProofStatus =
         UndeterminedProof  -- ^ All steps are unannotated
       | CompleteProof      -- ^ The proof is complete: no annotated sorry,
                            --  no annotated solved step
       | IncompleteProof    -- ^ There is a annotated sorry,
                            --   but no annotatd solved step.
       | TraceFound         -- ^ There is an annotated solved step

instance Monoid ProofStatus where
    mempty = CompleteProof

    mappend TraceFound _                        = TraceFound
    mappend _ TraceFound                        = TraceFound
    mappend IncompleteProof _                   = IncompleteProof
    mappend _ IncompleteProof                   = IncompleteProof
    mappend _ CompleteProof                     = CompleteProof
    mappend CompleteProof _                     = CompleteProof
    mappend UndeterminedProof UndeterminedProof = UndeterminedProof

-- | The status of a 'ProofStep'.
proofStepStatus :: ProofStep (Maybe a) -> ProofStatus
proofStepStatus (ProofStep _         Nothing ) = UndeterminedProof
proofStepStatus (ProofStep Solved    (Just _)) = TraceFound
proofStepStatus (ProofStep (Sorry _) (Just _)) = IncompleteProof
proofStepStatus (ProofStep _         (Just _)) = CompleteProof


{- TODO: Test and probably improve

-- | @proveSystem rules se@ tries to construct a proof that @se@ is valid.
-- This proof may contain 'Sorry' steps, if the prover is stuck. It can also be
-- of infinite depth, if the proof strategy loops.
proveSystemIterDeep :: ProofContext -> System -> Proof System
proveSystemIterDeep rules se0 =
    fromJust $ asum $ map (prove se0 . round) $ iterate (*1.5) (3::Double)
  where
    prove :: System -> Int -> Maybe (Proof System)
    prove se bound
      | bound < 0 = Nothing
      | otherwise =
          case next of
            [] -> pure $ sorry "prover stuck => possible attack found" se
            xs -> asum $ map mkProof xs
      where
        next = do m <- possibleProofMethods se
                  (m,) <$> maybe mzero return (execProofMethod rules m se)
        mkProof (method, cases) =
            LNode (ProofStep method se) <$> traverse (`prove` (bound - 1)) cases
-}

-- | @checkProof rules se prf@ replays the proof @prf@ against the start
-- sequent @se@. A failure to apply a proof method is denoted by a resulting
-- proof step without an annotated sequent. An unhandled case is denoted using
-- the 'Sorry' proof method.
checkProof :: ProofContext
           -> (Int -> System -> Proof (Maybe System)) -- prover for new cases in depth
           -> Int         -- ^ Original depth
           -> System
           -> Proof a
           -> Proof (Maybe a, Maybe System)
checkProof ctxt prover d sys prf@(LNode (ProofStep method info) cs) =
    case (method, execProofMethod ctxt method sys) of
        (Sorry reason, _         ) -> sorryNode reason cs
        (_           , Just cases) -> node method $ checkChildren cases
        (_           , Nothing   ) ->
            sorryNode (Just "invalid proof step encountered")
                      (M.singleton "" prf)
  where
    node m                 = LNode (ProofStep m (Just info, Just sys))
    sorryNode reason cases = node (Sorry reason) (M.map noSystemPrf cases)
    noSystemPrf            = mapProofInfo (\i -> (Just i, Nothing))

    checkChildren cases = mergeMapsWith
        unhandledCase noSystemPrf (checkProof ctxt prover (d + 1)) cases cs
      where
        unhandledCase = mapProofInfo ((,) Nothing) . prover d

-- | Annotate a proof with the constraint systems of all intermediate steps
-- under the assumption that all proof steps are valid. If some proof steps
-- might be invalid, then you must use 'checkProof', which handles them
-- gracefully.
annotateWithSystems :: ProofContext -> System -> Proof () -> Proof System
annotateWithSystems ctxt =
    go
  where
    -- Here we are careful to construct the result such that an inspection of
    -- the proof does not force the recomputed constraint systems.
    go sysOrig (LNode (ProofStep method _) csOrig) =
      LNode (ProofStep method sysOrig) $ M.fromList $ do
          (name, prf) <- M.toList csOrig
          let sysAnn = extract ("case '" ++ name ++ "' non-existent") $
                       M.lookup name csAnn
          return (name, go sysAnn prf)
      where
        extract msg = fromMaybe (error $ "annotateWithSystems: " ++ msg)
        csAnn       = extract "proof method execution failed" $
                      execProofMethod ctxt method sysOrig


------------------------------------------------------------------------------
-- Provers: the interface to the outside world.
------------------------------------------------------------------------------

-- | Incremental proofs are used to represent intermediate results of proof
-- checking/construction.
type IncrementalProof = Proof (Maybe System)

-- | Provers whose sequencing is handled via the 'Monoid' instance.
--
-- > p1 `mappend` p2
--
-- Is a prover that first runs p1 and then p2 on the resulting proof.
newtype Prover =  Prover
          { runProver
              :: ProofContext              -- proof rules to use
              -> Int                       -- proof depth
              -> System                    -- original sequent to start with
              -> IncrementalProof          -- original proof
              -> Maybe IncrementalProof    -- resulting proof
          }

instance Monoid Prover where
    mempty          = Prover $ \_  _ _ -> Just
    p1 `mappend` p2 = Prover $ \ctxt d se ->
        runProver p1 ctxt d se >=> runProver p2 ctxt d se

-- | Map the proof generated by the prover.
mapProverProof :: (IncrementalProof -> IncrementalProof) -> Prover -> Prover
mapProverProof f p = Prover $ \ ctxt d se prf -> f <$> runProver p ctxt d se prf

-- | Prover that always fails.
failProver :: Prover
failProver = Prover (\ _ _ _ _ -> Nothing)

-- | Resorts to the second prover, if the first one is not successful.
orelse :: Prover -> Prover -> Prover
orelse p1 p2 = Prover $ \ctxt d se prf ->
    runProver p1 ctxt d se prf `mplus` runProver p2 ctxt d se prf

-- | Try to apply a prover. If it fails, just return the original proof.
tryProver :: Prover -> Prover
tryProver =  (`orelse` mempty)

-- | Try to execute one proof step using the given proof method.
oneStepProver :: ProofMethod -> Prover
oneStepProver method = Prover $ \ctxt _ se _ -> do
    cases <- execProofMethod ctxt method se
    return $ LNode (ProofStep method (Just se)) (M.map (unproven . Just) cases)

-- | Replace the current proof with a sorry step and the given reason.
sorryProver :: Maybe String -> Prover
sorryProver reason = Prover $ \_ _ se _ -> return $ sorry reason (Just se)

-- | Apply a prover only to a sub-proof, fails if the subproof doesn't exist.
focus :: ProofPath -> Prover -> Prover
focus []   prover = prover
focus path prover =
    Prover $ \ctxt d _ prf ->
        modifyAtPath (prover' ctxt (d + length path)) path prf
  where
    prover' ctxt d prf = do
        se <- psInfo (root prf)
        runProver prover ctxt d se prf

-- | Check the proof and handle new cases using the given prover.
checkAndExtendProver :: Prover -> Prover
checkAndExtendProver prover0 = Prover $ \ctxt d se prf ->
    return $ mapProofInfo snd $ checkProof ctxt (prover ctxt) d se prf
  where
    unhandledCase   = sorry (Just "unhandled case") Nothing
    prover ctxt d se =
        fromMaybe unhandledCase $ runProver prover0 ctxt d se unhandledCase

-- | Replace all annotated sorry steps using the given prover.
replaceSorryProver :: Prover -> Prover
replaceSorryProver prover0 = Prover prover
  where
    prover ctxt d _ = return . replace
      where
        replace prf@(LNode (ProofStep (Sorry _) (Just se)) _) =
            fromMaybe prf $ runProver prover0 ctxt d se prf
        replace (LNode ps cases) =
            LNode ps $ M.map replace cases


-- | Use the first prover that works.
firstProver :: [Prover] -> Prover
firstProver = foldr orelse failProver

-- | Prover that does one contradiction step.
contradictionProver :: Prover
contradictionProver = Prover $ \ctxt d sys prf ->
    runProver
        (firstProver $ map oneStepProver $
            (Contradiction . Just <$> contradictions ctxt sys))
        ctxt d sys prf

------------------------------------------------------------------------------
-- Automatic Prover's
------------------------------------------------------------------------------

data SolutionExtractor = CutDFS | CutBFS | CutNothing
    deriving( Eq, Ord, Show, Read )

data AutoProver = AutoProver
    { apHeuristic :: Heuristic
    , apBound     :: Maybe Int
    , apCut       :: SolutionExtractor
    }

runAutoProver :: AutoProver -> Prover
runAutoProver (AutoProver heuristic bound cut) =
    mapProverProof cutSolved $ maybe id boundProver bound autoProver
  where
    cutSolved = case cut of
      CutDFS     -> cutOnSolvedDFS
      CutBFS     -> cutOnSolvedBFS
      CutNothing -> id

    -- | The standard automatic prover that ignores the existing proof and
    -- tries to find one by itself.
    autoProver :: Prover
    autoProver = Prover $ \ctxt depth sys _ ->
        return $ fmap (fmap Just)
               $ annotateWithSystems ctxt sys
               $ proveSystemDFS heuristic ctxt depth sys

    -- | Bound the depth of proofs generated by the given prover.
    boundProver :: Int -> Prover -> Prover
    boundProver b p = Prover $ \ctxt d se prf ->
        boundProofDepth b <$> runProver p ctxt d se prf


-- | The result of one pass of iterative deepening.
data IterDeepRes = NoSolution | MaybeNoSolution | Solution ProofPath

instance Monoid IterDeepRes where
    mempty = NoSolution

    x@(Solution _)   `mappend` _                = x
    _                `mappend` y@(Solution _)   = y
    MaybeNoSolution  `mappend` _                = MaybeNoSolution
    _                `mappend` MaybeNoSolution  = MaybeNoSolution
    NoSolution       `mappend` NoSolution       = NoSolution

-- | @cutOnSolvedDFS prf@ removes all other cases if an attack is found. The
-- attack search is performed using a parallel DFS traversal with iterative
-- deepening.
--
-- FIXME: Note that this function may use a lot of space, as it holds onto the
-- whole proof tree.
cutOnSolvedDFS :: Proof (Maybe a) -> Proof (Maybe a)
cutOnSolvedDFS prf0 =
    go (4 :: Integer) $ insertPaths prf0
  where
    go dMax prf = case findSolved 0 prf of
        NoSolution      -> prf0
        MaybeNoSolution -> go (2 * dMax) prf
        Solution path   -> extractSolved path prf0
      where
        findSolved d node
          | d >= dMax = MaybeNoSolution
          | otherwise = case node of
              -- do not search in nodes that are not annotated
              LNode (ProofStep _      (Nothing, _   )) _  -> NoSolution
              LNode (ProofStep Solved (Just _ , path)) _  -> Solution path
              LNode (ProofStep _      (Just _ , _   )) cs ->
                  foldMap (findSolved (succ d))
                      (cs `using` parTraversable nfProofMethod)

        nfProofMethod node = do
            void $ rseq (psMethod $ root node)
            void $ rseq (psInfo   $ root node)
            void $ rseq (children node)
            return node

    extractSolved []         p               = p
    extractSolved (label:ps) (LNode pstep m) = case M.lookup label m of
        Just subprf ->
          LNode pstep (M.fromList [(label, extractSolved ps subprf)])
        Nothing     ->
          error "Theory.Constraint.cutOnSolvedDFS: impossible, extractSolved failed, invalid path"

-- | Search for attacks in a BFS manner.
cutOnSolvedBFS :: Proof (Maybe a) -> Proof (Maybe a)
cutOnSolvedBFS =
    go (1::Int)
  where
    go l prf =
      -- FIXME: See if that poor man's logging could be done better.
      trace ("searching for attacks at depth: " ++ show l) $
        case S.runState (checkLevel l prf) CompleteProof of
          (_, UndeterminedProof) -> error "cutOnSolvedBFS: impossible"
          (_, CompleteProof)     -> prf
          (_, IncompleteProof)   -> go (l+1) prf
          (prf', TraceFound)     ->
              trace ("attack found at depth: " ++ show l) prf'

    checkLevel 0 (LNode  step@(ProofStep Solved (Just _)) _) =
        S.put TraceFound >> return (LNode step M.empty)
    checkLevel 0 prf@(LNode (ProofStep _ x) cs)
      | M.null cs = return prf
      | otherwise = do
          st <- S.get
          msg <- case st of
              TraceFound -> return $ "ignored (attack exists)"
              _           -> S.put IncompleteProof >> return "bound reached"
          return $ LNode (ProofStep (Sorry (Just msg)) x) M.empty
    checkLevel l prf@(LNode step cs)
      | isNothing (psInfo step) = return prf
      | otherwise               = LNode step <$> traverse (checkLevel (l-1)) cs


-- | @proveSystemDFS rules se@ explores all solutions of the initial
-- constraint system using a depth-first-search strategy to resolve the
-- non-determinism wrt. what goal to solve next.  This proof can be of
-- infinite depth, if the proof strategy loops.
--
-- Use 'annotateWithSystems' to annotate the proof tree with the constraint
-- systems.
proveSystemDFS :: Heuristic -> ProofContext -> Int -> System -> Proof ()
proveSystemDFS heuristic ctxt d0 sys0 =
    prove d0 sys0
  where
    prove !depth sys =
        case rankProofMethods (useHeuristic heuristic depth) ctxt sys of
          []                         -> node Solved M.empty
          (method, (cases, _expl)):_ -> node method cases
      where
        node method cases =
          LNode (ProofStep method ()) (M.map (prove (succ depth)) cases)


------------------------------------------------------------------------------
-- Pretty printing
------------------------------------------------------------------------------


prettyProof :: HighlightDocument d => Proof a -> d
prettyProof = prettyProofWith (prettyProofMethod . psMethod) (const id)

prettyProofWith :: HighlightDocument d
                => (ProofStep a -> d)      -- ^ Make proof step pretty
                -> (ProofStep a -> d -> d) -- ^ Make whole case pretty
                -> Proof a                 -- ^ The proof to prettify
                -> d
prettyProofWith prettyStep prettyCase =
    ppPrf
  where
    ppPrf (LNode ps cs) = ppCases ps (M.toList cs)

    ppCases ps@(ProofStep Solved _) [] = prettyStep ps
    ppCases ps []                      = prettyCase ps (kwBy <> text " ")
                                           <> prettyStep ps
    ppCases ps [("", prf)]             = prettyStep ps $-$ ppPrf prf
    ppCases ps cases                   =
        prettyStep ps $-$
        (vcat $ intersperse (prettyCase ps kwNext) $ map ppCase cases) $-$
        prettyCase ps kwQED

    ppCase (name, prf) = nest 2 $
      (prettyCase (root prf) $ kwCase <-> text name) $-$
      ppPrf prf

-- | Convert a proof status to a redable string.
showProofStatus :: SystemTraceQuantifier -> ProofStatus -> String
showProofStatus ExistsNoTrace   TraceFound        = "falsified - found trace"
showProofStatus ExistsNoTrace   CompleteProof     = "verified"
showProofStatus ExistsSomeTrace CompleteProof     = "falsified - no trace found"
showProofStatus ExistsSomeTrace TraceFound        = "verified"
showProofStatus _               IncompleteProof   = "analysis incomplete"
showProofStatus _               UndeterminedProof = "analysis undetermined"


-- Derived instances
--------------------

$( derive makeBinary ''ProofStep)
$( derive makeBinary ''ProofStatus)
$( derive makeBinary ''SolutionExtractor)
$( derive makeBinary ''AutoProver)

$( derive makeNFData ''ProofStep)
$( derive makeNFData ''ProofStatus)
$( derive makeNFData ''SolutionExtractor)
$( derive makeNFData ''AutoProver)

instance (Ord l, NFData l, NFData a) => NFData (LTree l a) where
  rnf (LNode r m) = rnf r `seq` rnf  m

instance (Ord l, Binary l, Binary a) => Binary (LTree l a) where
  put (LNode r m) = put r >> put m
  get = LNode <$> get <*> get