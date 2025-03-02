module MainFrame.State
  ( Env(..)
  , mkMainFrame
  , handleAction
  , mkInitialState
  ) where

import AjaxUtils (AjaxErrorPaneAction(..), ajaxErrorRefLabel)
import Analytics (analyticsTracking)
import Animation (class MonadAnimate, animate)
import Chain.State (handleAction) as Chain
import Chain.Types (Action(..), AnnotatedBlockchain(..), _chainFocusAppearing, _txIdOf)
import Chain.Types (initialState) as Chain
import Clipboard (class MonadClipboard)
import Control.Monad.Error.Class (class MonadThrow, throwError)
import Control.Monad.Except.Extra (noteT)
import Control.Monad.Except.Trans (ExceptT(..), except, runExceptT)
import Control.Monad.Maybe.Extra (hoistMaybe)
import Control.Monad.Maybe.Trans (MaybeT(..), runMaybeT)
import Control.Monad.Reader (class MonadAsk, runReaderT)
import Control.Monad.State.Class (class MonadState, gets)
import Control.Monad.State.Extra (zoomStateT)
import Control.Monad.Trans.Class (lift)
import Cursor (_current)
import Cursor as Cursor
import Data.Argonaut.Decode (printJsonDecodeError)
import Data.Argonaut.Extra (parseDecodeJson, encodeStringifyJson)
import Data.Array (catMaybes, (..))
import Data.Array (deleteAt, snoc) as Array
import Data.Array.Extra (move) as Array
import Data.Bifunctor (lmap)
import Data.BigInt.Argonaut (BigInt)
import Data.BigInt.Argonaut as BigInt
import Data.Either (Either(..), either, note)
import Data.Lens (assign, modifying, over, to, traversed, use, view)
import Data.Lens.Extra (peruse)
import Data.Lens.Fold (maximumOf, lastOf, preview)
import Data.Lens.Index (ix)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.MediaType.Common (textPlain)
import Data.Newtype (unwrap)
import Data.RawJson (RawJson(..))
import Data.Semigroup (append)
import Data.String as String
import Data.Traversable (traverse)
import Editor.Lenses (_currentCodeIsCompiled, _feedbackPaneMinimised, _lastCompiledCode)
import Editor.State (initialState) as Editor
import Editor.Types (Action(..), State) as Editor
import Effect.Aff.Class (class MonadAff)
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Exception (Error, error)
import Gist (_GistId, gistId)
import Gists.Types (GistAction(..))
import Gists.Types as Gists
import Halogen (Component, hoist)
import Halogen as H
import Halogen.Query (HalogenM)
import Language.Haskell.Interpreter (CompilationError(..), InterpreterError(..), SourceCode(..))
import Ledger.CardanoWallet (WalletNumber(WalletNumber))
import MainFrame.Lenses (_actionDrag, _authStatus, _blockchainVisualisationState, _compilationResult, _contractDemos, _createGistResult, _currentDemoName, _currentView, _demoFilesMenuVisible, _editorState, _evaluationResult, _functionSchema, _gistErrorPaneVisible, _gistUrl, _knownCurrencies, _lastEvaluatedSimulation, _lastSuccessfulCompilationResult, _resultRollup, _simulationActions, _simulationId, _simulationWallets, _simulations, _successfulCompilationResult, _successfulEvaluationResult, getKnownCurrencies)
import MainFrame.MonadApp (class MonadApp, editorGetContents, editorHandleAction, editorSetAnnotations, editorSetContents, getGistByGistId, getOauthStatus, postGistByGistId, postContract, postEvaluation, postGist, preventDefault, resizeBalancesChart, resizeEditor, runHalogenApp, saveBuffer, scrollIntoView, setDataTransferData, setDropEffect)
import MainFrame.Types (ChildSlots, DragAndDropEventType(..), HAction(..), Query, State(..), View(..), WalletEvent(..))
import MainFrame.View (render)
import Monaco (IMarkerData, markerSeverity)
import Network.RemoteData (RemoteData(..), _Success, isSuccess)
import Playground.Gists (mkNewGist, playgroundGistFile, simulationGistFile)
import Playground.Server (class HasSPSettings, SPSettings_)
import Playground.Types (ContractCall(..), ContractDemo(..), Evaluation(..), KnownCurrency, Simulation(..), SimulatorWallet(..), _CallEndpoint, _FunctionSchema)
import Plutus.V1.Ledger.Value (Value)
import Prelude (class Applicative, Unit, Void, add, const, bind, discard, flip, identity, join, not, mempty, one, pure, show, unit, unless, void, when, zero, (+), ($), (&&), (==), (<>), (<$>), (<*>), (>>=), (<<<))
import Schema.Types (Expression, FormArgument, SimulationAction(..), formArgumentToJson, handleActionEvent, handleFormEvent, handleValueEvent, mkInitialValue, traverseFunctionSchema)
import Servant.PureScript (printAjaxError)
import Simulator.View (simulatorTitleRefLabel, simulationsErrorRefLabel)
import StaticData (mkContractDemos, lookupContractDemo)
import Validation (_argumentValues, _argument)
import Wallet.Lenses (_simulatorWalletBalance, _simulatorWalletWallet, _walletId)
import Web.HTML.Event.DataTransfer as DataTransfer

mkSimulatorWallet :: Array KnownCurrency -> BigInt -> SimulatorWallet
mkSimulatorWallet currencies walletId =
  SimulatorWallet
    { simulatorWalletWallet: WalletNumber { getWallet: walletId }
    , simulatorWalletBalance: mkInitialValue currencies (BigInt.fromInt 100_000_000)
    }

mkSimulation :: Array KnownCurrency -> Int -> Simulation
mkSimulation simulationCurrencies simulationId =
  Simulation
    { simulationName: "Simulation " <> show simulationId
    , simulationId
    , simulationActions: []
    , simulationWallets: mkSimulatorWallet simulationCurrencies <<< BigInt.fromInt <$> 1 .. 2
    }

mkInitialState :: forall m. MonadThrow Error m => Editor.State -> m State
mkInitialState editorState = do
  contractDemos <-
    either
      ( throwError
          <<< error
          <<< append "Could not load demo scripts. Parsing errors: "
          <<< printJsonDecodeError
      )
      pure
      mkContractDemos
  pure
    $ State
        { demoFilesMenuVisible: false
        , gistErrorPaneVisible: true
        , currentView: Editor
        , editorState
        , contractDemos
        , currentDemoName: Nothing
        , compilationResult: NotAsked
        , lastSuccessfulCompilationResult: Nothing
        , simulations: Cursor.empty
        , actionDrag: Nothing
        , evaluationResult: NotAsked
        , lastEvaluatedSimulation: Nothing
        , authStatus: NotAsked
        , createGistResult: NotAsked
        , gistUrl: Nothing
        , blockchainVisualisationState: Chain.initialState
        }

------------------------------------------------------------
newtype Env
  = Env { spSettings :: SPSettings_ }

instance hasSPSettingsEnv :: HasSPSettings Env where
  spSettings (Env e) = e.spSettings

mkMainFrame ::
  forall m n.
  MonadThrow Error n =>
  MonadEffect n =>
  MonadAff m =>
  n (Component Query HAction Void m)
mkMainFrame = do
  editorState <- Editor.initialState
  initialState <- mkInitialState editorState
  pure $ hoist (flip runReaderT $ Env { spSettings: { baseURL: "/api/" } })
    $ H.mkComponent
        { initialState: const initialState
        , render
        , eval:
            H.mkEval
              { handleAction: handleActionWithAnalyticsTracking
              , handleQuery: const $ pure Nothing
              , initialize: Just Init
              , receive: const Nothing
              , finalize: Nothing
              }
        }

-- TODO: use web-common withAnalytics function
handleActionWithAnalyticsTracking ::
  forall env m.
  HasSPSettings env =>
  MonadAsk env m =>
  MonadEffect m =>
  MonadAff m =>
  HAction -> HalogenM State HAction ChildSlots Void m Unit
handleActionWithAnalyticsTracking action = do
  liftEffect $ analyticsTracking action
  runHalogenApp $ handleAction action

handleAction ::
  forall env m.
  HasSPSettings env =>
  MonadState State m =>
  MonadClipboard m =>
  MonadAsk env m =>
  MonadApp m =>
  MonadAnimate m State =>
  HAction -> m Unit
handleAction Init = do
  handleAction CheckAuthStatus
  editorHandleAction $ Editor.Init

handleAction Mounted = pure unit

handleAction (EditorAction action) = editorHandleAction action

handleAction (ActionDragAndDrop index DragStart event) = do
  setDataTransferData event textPlain (show index)
  assign _actionDrag (Just index)

handleAction (ActionDragAndDrop _ DragEnd _) = assign _actionDrag Nothing

handleAction (ActionDragAndDrop _ DragEnter event) = do
  preventDefault event
  setDropEffect DataTransfer.Move event

handleAction (ActionDragAndDrop _ DragOver event) = do
  preventDefault event
  setDropEffect DataTransfer.Move event

handleAction (ActionDragAndDrop _ DragLeave _) = pure unit

handleAction (ActionDragAndDrop destination Drop event) = do
  use _actionDrag
    >>= case _ of
        Just source -> modifying (_simulations <<< _current <<< _simulationActions) (Array.move source destination)
        _ -> pure unit
  preventDefault event
  assign _actionDrag Nothing

-- We just ignore most Chartist events.
handleAction (HandleBalancesChartMessage _) = pure unit

handleAction CheckAuthStatus = do
  assign _authStatus Loading
  authResult <- getOauthStatus
  assign _authStatus authResult

handleAction (GistAction subEvent) = handleGistAction subEvent

handleAction ToggleDemoFilesMenu = modifying _demoFilesMenuVisible not

handleAction (ChangeView view) = do
  assign _currentView view
  when (view == Editor) resizeEditor
  when (view == Transactions) resizeBalancesChart

handleAction EvaluateActions =
  void
    $ runMaybeT
    $ do
        simulation <- peruse (_simulations <<< _current)
        evaluation <-
          MaybeT do
            contents <- editorGetContents
            pure $ join $ toEvaluation <$> contents <*> simulation
        assign _evaluationResult Loading
        result <- lift $ postEvaluation evaluation
        assign _evaluationResult result
        case result of
          Success (Right _) -> do
            -- on successful evaluation, update last evaluated simulation, and reset and show transactions
            when (isSuccess result) do
              assign _lastEvaluatedSimulation simulation
              assign _blockchainVisualisationState Chain.initialState
              -- preselect the first transaction (if any)
              mAnnotatedBlockchain <- peruse (_successfulEvaluationResult <<< _resultRollup <<< to AnnotatedBlockchain)
              txId <- (gets <<< lastOf) (_successfulEvaluationResult <<< _resultRollup <<< traversed <<< traversed <<< _txIdOf)
              lift $ zoomStateT _blockchainVisualisationState $ Chain.handleAction (FocusTx txId) mAnnotatedBlockchain
            replaceViewOnSuccess result Simulations Transactions
            lift $ scrollIntoView simulatorTitleRefLabel
          Success (Left _) -> do
            -- on failed evaluation, scroll the error pane into view
            lift $ scrollIntoView simulationsErrorRefLabel
          Failure _ -> do
            -- on failed response, scroll the ajax error pane into view
            lift $ scrollIntoView ajaxErrorRefLabel
          _ -> pure unit
        pure unit

handleAction (LoadScript key) = do
  contractDemos <- use _contractDemos
  case lookupContractDemo key contractDemos of
    Nothing -> pure unit
    Just (ContractDemo { contractDemoName, contractDemoEditorContents, contractDemoSimulations, contractDemoContext }) -> do
      editorSetContents contractDemoEditorContents (Just 1)
      saveBuffer (unwrap contractDemoEditorContents)
      assign _demoFilesMenuVisible false
      assign _currentView Editor
      assign _currentDemoName (Just contractDemoName)
      assign _simulations $ Cursor.fromArray contractDemoSimulations
      assign (_editorState <<< _lastCompiledCode) (Just contractDemoEditorContents)
      assign (_editorState <<< _currentCodeIsCompiled) true
      assign _compilationResult (Success <<< Right $ contractDemoContext)
      assign _evaluationResult NotAsked
      assign _createGistResult NotAsked

-- Note: the following three cases involve some temporary fudges that should become
-- unnecessary when we remodel and have one evaluationResult per simulation. In
-- particular: we prevent simulation changes while the evaluationResult is Loading,
-- and switch to the simulations view (from transactions) following any change
handleAction AddSimulationSlot = do
  evaluationResult <- use _evaluationResult
  case evaluationResult of
    Loading -> pure unit
    _ -> do
      knownCurrencies <- getKnownCurrencies
      mSignatures <- peruse (_successfulCompilationResult <<< _functionSchema)
      case mSignatures of
        Just _ ->
          modifying _simulations
            ( \simulations ->
                let
                  maxsimulationId = fromMaybe 0 $ maximumOf (traversed <<< _simulationId) simulations

                  simulationId = maxsimulationId + 1
                in
                  Cursor.snoc simulations
                    (mkSimulation knownCurrencies simulationId)
            )
        Nothing -> pure unit
      assign _currentView Simulations

handleAction (SetSimulationSlot index) = do
  evaluationResult <- use _evaluationResult
  case evaluationResult of
    Loading -> pure unit
    _ -> do
      modifying _simulations (Cursor.setIndex index)
      assign _currentView Simulations

handleAction (RemoveSimulationSlot index) = do
  evaluationResult <- use _evaluationResult
  case evaluationResult of
    Loading -> pure unit
    _ -> do
      simulations <- use _simulations
      if (Cursor.getIndex simulations) == index then
        assign _currentView Simulations
      else
        pure unit
      modifying _simulations (Cursor.deleteAt index)

handleAction (ModifyWallets action) = do
  knownCurrencies <- getKnownCurrencies
  modifying (_simulations <<< _current <<< _simulationWallets) (handleActionWalletEvent (mkSimulatorWallet knownCurrencies) action)

handleAction (ChangeSimulation subaction) = do
  knownCurrencies <- getKnownCurrencies
  let
    initialValue = mkInitialValue knownCurrencies zero
  modifying (_simulations <<< _current <<< _simulationActions) (handleSimulationAction initialValue subaction)

handleAction (ChainAction subaction) = do
  mAnnotatedBlockchain <-
    peruse (_successfulEvaluationResult <<< _resultRollup <<< to AnnotatedBlockchain)
  let
    wrapper = case subaction of
      (FocusTx _) -> animate (_blockchainVisualisationState <<< _chainFocusAppearing)
      _ -> identity
  wrapper
    $ zoomStateT _blockchainVisualisationState
    $ Chain.handleAction subaction mAnnotatedBlockchain

handleAction CompileProgram = do
  mContents <- editorGetContents
  case mContents of
    Nothing -> pure unit
    Just contents -> do
      oldSuccessfulCompilationResult <- use _lastSuccessfulCompilationResult
      assign _compilationResult Loading
      newCompilationResult <- postContract contents
      assign _compilationResult newCompilationResult
      -- If we got a successful result, update lastCompiledCode and switch tab.
      case newCompilationResult of
        Success (Left _) -> assign (_editorState <<< _feedbackPaneMinimised) false
        _ ->
          when (isSuccess newCompilationResult) do
            assign (_editorState <<< _lastCompiledCode) (Just contents)
            assign (_editorState <<< _currentCodeIsCompiled) true
      -- Update the error display.
      editorSetAnnotations
        $ case newCompilationResult of
            Success (Left errors) -> toAnnotations errors
            _ -> []
      -- If we have a result with new signatures, we can only hold
      -- onto the old actions if the signatures still match. Any
      -- change means we'll have to clear out the existing simulation.
      -- Same thing for currencies.
      -- Potentially we could be smarter about this. But for now,
      -- let's at least be correct.
      newSuccessfulCompilationResult <- use _lastSuccessfulCompilationResult
      let
        oldSignatures = view _functionSchema <$> oldSuccessfulCompilationResult

        newSignatures = view _functionSchema <$> newSuccessfulCompilationResult

        oldCurrencies = view _knownCurrencies <$> oldSuccessfulCompilationResult

        newCurrencies = view _knownCurrencies <$> newSuccessfulCompilationResult
      unless
        ( oldSignatures == newSignatures
            && oldCurrencies
            == newCurrencies
        )
        ( assign _simulations
            $ case newCurrencies of
                Just currencies -> Cursor.singleton $ mkSimulation currencies 1
                Nothing -> Cursor.empty
        )
      pure unit

handleSimulationAction ::
  Value ->
  SimulationAction ->
  Array (ContractCall FormArgument) ->
  Array (ContractCall FormArgument)
handleSimulationAction _ (ModifyActions actionEvent) = handleActionEvent actionEvent

handleSimulationAction initialValue (PopulateAction n event) = do
  over
    ( ix n
        <<< _CallEndpoint
        <<< _argumentValues
        <<< _FunctionSchema
        <<< _argument
    )
    $ handleFormEvent initialValue event

handleGistAction :: forall m. MonadApp m => MonadState State m => GistAction -> m Unit
handleGistAction PublishOrUpdateGist = do
  void
    $ runMaybeT do
        mContents <- lift $ editorGetContents
        simulations <- use _simulations
        newGist <- hoistMaybe $ mkNewGist { source: mContents, simulations }
        mGist <- use _createGistResult
        assign _createGistResult Loading
        newResult <-
          lift
            $ case preview (_Success <<< gistId) mGist of
                Nothing -> postGist newGist
                Just existingGistId -> postGistByGistId newGist existingGistId
        assign _createGistResult newResult
        gistId <- hoistMaybe $ preview (_Success <<< gistId <<< _GistId) newResult
        assign _gistUrl (Just gistId)
        when (isSuccess newResult) do
          assign _currentView Editor
          assign _currentDemoName Nothing

handleGistAction (SetGistUrl newGistUrl) = assign _gistUrl (Just newGistUrl)

handleGistAction LoadGist =
  void $ runExceptT
    $ do
        mGistId <- ExceptT (note "Gist Url not set." <$> use _gistUrl)
        eGistId <- except $ Gists.parseGistUrl mGistId
        --
        assign _createGistResult Loading
        assign _gistErrorPaneVisible true
        aGist <- lift $ getGistByGistId eGistId
        assign _createGistResult aGist
        when (isSuccess aGist) do
          assign _currentView Editor
          assign _currentDemoName Nothing
        gist <-
          except
            $ toEither (Left "Gist not loaded.")
            $ lmap printAjaxError aGist
        --
        -- Load the source, if available.
        content <- noteT "Source not found in gist." $ view playgroundGistFile gist
        lift $ editorSetContents (SourceCode content) (Just 1)
        lift $ saveBuffer content
        assign _simulations Cursor.empty
        assign _evaluationResult NotAsked
        --
        -- Load the simulation, if available.
        simulationString <- noteT "Simulation not found in gist." $ view simulationGistFile gist
        simulations <- except $ lmap printJsonDecodeError $ parseDecodeJson simulationString
        assign _simulations simulations
  where
  toEither :: forall e a. Either e a -> RemoteData e a -> Either e a
  toEither _ (Success a) = Right a

  toEither _ (Failure e) = Left e

  toEither x Loading = x

  toEither x NotAsked = x

handleGistAction (AjaxErrorPaneAction CloseErrorPane) = assign _gistErrorPaneVisible false

handleActionWalletEvent :: (BigInt -> SimulatorWallet) -> WalletEvent -> Array SimulatorWallet -> Array SimulatorWallet
handleActionWalletEvent mkWallet AddWallet wallets =
  let
    maxWalletId = fromMaybe zero $ maximumOf (traversed <<< _simulatorWalletWallet <<< _walletId) wallets

    newWallet = mkWallet (add one maxWalletId)
  in
    Array.snoc wallets newWallet

handleActionWalletEvent _ (RemoveWallet index) wallets = fromMaybe wallets $ Array.deleteAt index wallets

handleActionWalletEvent _ (ModifyBalance walletIndex action) wallets =
  over
    (ix walletIndex <<< _simulatorWalletBalance)
    (handleValueEvent action)
    wallets

replaceViewOnSuccess :: forall m e a. MonadState State m => RemoteData e a -> View -> View -> m Unit
replaceViewOnSuccess result source target = do
  currentView <- use _currentView
  when (isSuccess result && currentView == source)
    (assign _currentView target)

------------------------------------------------------------
toEvaluation :: SourceCode -> Simulation -> Maybe Evaluation
toEvaluation sourceCode (Simulation { simulationActions, simulationWallets }) = do
  program <- RawJson <<< encodeStringifyJson <$> traverse toExpression simulationActions
  pure
    $ Evaluation
        { wallets: simulationWallets
        , program
        , sourceCode
        }

toExpression :: ContractCall FormArgument -> Maybe Expression
toExpression = traverseContractCall encodeForm
  where
  encodeForm :: FormArgument -> Maybe RawJson
  encodeForm argument = (RawJson <<< encodeStringifyJson) <$> formArgumentToJson argument

traverseContractCall ::
  forall m b a.
  Applicative m =>
  (a -> m b) ->
  ContractCall a -> m (ContractCall b)
traverseContractCall _ (AddBlocks addBlocks) = pure $ AddBlocks addBlocks

traverseContractCall _ (AddBlocksUntil addBlocksUntil) = pure $ AddBlocksUntil addBlocksUntil

traverseContractCall _ (PayToWallet payToWallet) = pure $ PayToWallet payToWallet

traverseContractCall f (CallEndpoint { caller, argumentValues: oldArgumentValues }) = rewrap <$> traverseFunctionSchema f oldArgumentValues
  where
  rewrap newArgumentValues = CallEndpoint { caller, argumentValues: newArgumentValues }

toAnnotations :: InterpreterError -> Array IMarkerData
toAnnotations (TimeoutError _) = []

toAnnotations (CompilationErrors errors) = catMaybes (toAnnotation <$> errors)

toAnnotation :: CompilationError -> Maybe IMarkerData
toAnnotation (RawError _) = Nothing

toAnnotation (CompilationError { row, column, text }) =
  Just
    { severity: markerSeverity "Error"
    , message: String.joinWith "\\n" text
    , startLineNumber: row
    , startColumn: column
    , endLineNumber: row
    , endColumn: column
    , code: mempty
    , source: mempty
    }
