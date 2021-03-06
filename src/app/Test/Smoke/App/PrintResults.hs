{-# LANGUAGE OverloadedStrings #-}

module Test.Smoke.App.PrintResults
  ( printResult,
  )
where

import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ask)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import System.IO.Error (ioeGetErrorString)
import Test.Smoke
import Test.Smoke.App.Diff
import Test.Smoke.App.OptionTypes
import Test.Smoke.App.Print
import Test.Smoke.App.PrintErrors
import Test.Smoke.Paths
import Text.Printf (printf)

data PartName = ShortName String | LongName String

printResult :: TestResult -> Output ()
printResult result@(TestResult testPlan@TestPlan {planTest = test} statusResult stdOutResult stdErrResult fileResults)
  | isSuccess result =
    putGreenLn "  succeeded"
  | otherwise = do
    printFailingInput
      "args"
      ( Text.unlines . Vector.toList . Vector.map fromString . unArgs
          <$> testArgs test
      )
    printFailingInput "input" (planStdIn testPlan <$ testStdIn test)
    printFailingOutput "status" (toAssertionResult ((<> "\n") . showInt . unStatus <$> statusResult))
    printFailingOutput "stdout" stdOutResult
    printFailingOutput "stderr" stdErrResult
    printFailingFilesOutput fileResults
printResult (TestError _ testError) = printTestError testError
printResult (TestIgnored _) = putYellowLn "  ignored"

printFailingInput :: (Foldable f, FixtureType a) => String -> f a -> Output ()
printFailingInput name value =
  forM_ value $ \v -> do
    putRed $ fromString $ indentedKey ("  " ++ name ++ ":")
    putPlainLn $ indented outputIndentation (serializeFixture v)

printFailingOutput :: FixtureType a => String -> AssertionResult a -> Output ()
printFailingOutput name = printFailures (ShortName name)

printFailingFilesOutput ::
  Map (RelativePath File) (AssertionResult TestFileContents) -> Output ()
printFailingFilesOutput fileResults =
  if all isSuccess (Map.elems fileResults)
    then return ()
    else do
      putRedLn "  files:"
      forM_ (Map.assocs fileResults) $ uncurry printFailingFileOutput

printFailingFileOutput :: FixtureType a => RelativePath File -> AssertionResult a -> Output ()
printFailingFileOutput path = printFailures (LongName ("  " ++ toFilePath path))

printFailures :: FixtureType a => PartName -> AssertionResult a -> Output ()
printFailures _ AssertionSuccess =
  return ()
printFailures name (AssertionFailure (SingleAssertionFailure failure)) = do
  printFailureName name (failureIsInline failure)
  printFailure failure
printFailures name (AssertionFailure (MultipleAssertionFailures failures)) = do
  printFailureName name isInline
  printFailure firstFailure
  forM_ (Vector.tail failures) $ \failure -> do
    putRed "      or:"
    when isInline $ putPlain " "
    printFailure failure
  where
    firstFailure = Vector.head failures
    isInline = failureIsInline firstFailure

printFailureName :: PartName -> Bool -> Output ()
printFailureName (ShortName name) isInline = do
  putRed $ "  " <> Text.pack name <> ":"
  when isInline $ putPlain $ Text.replicate (outputIndentation - length name - 3) " "
printFailureName (LongName name) _ = do
  putRedLn $ "  " <> Text.pack name <> ":"
  putPlain $ fromString $ indentedKey ""

failureIsInline :: AssertionFailure a -> Bool
failureIsInline AssertionFailureDiff {} = True
failureIsInline AssertionFailureContains {} = False
failureIsInline AssertionFailureExpectedFileError {} = True
failureIsInline AssertionFailureActualFileError {} = True

printFailure :: FixtureType a => AssertionFailure a -> Output ()
printFailure (AssertionFailureDiff (Expected expected) (Actual actual)) =
  printDiff (serializeFixture expected) (serializeFixture actual)
printFailure (AssertionFailureContains (Expected expected) (Actual actual)) = do
  putPlainLn ""
  putRedLn "    expected to contain:"
  putRedLn $ indentedAll nestedOutputIndentation (serializeFixture expected)
  putRed "    actual: "
  putRedLn $ indented nestedOutputIndentation (serializeFixture actual)
printFailure (AssertionFailureExpectedFileError fileError (Actual actual)) = do
  printFailureFileError fileError
  putRed "    actual: "
  putRedLn $ indented nestedOutputIndentation (serializeFixture actual)
printFailure (AssertionFailureActualFileError fileError) =
  printFailureFileError fileError

printFailureFileError :: SmokeFileError -> Output ()
printFailureFileError (MissingFile path) = do
  putPlainLn ""
  putRedLn $ "    The fixture " <> showPath path <> " does not exist."
printFailureFileError (CouldNotReadFile _ exception) = do
  putRedLn $ fromString (ioeGetErrorString exception)

printDiff :: Text -> Text -> Output ()
printDiff left right = do
  AppOptions
    { optionsColor = color,
      optionsDiffEngine = DiffEngine {engineRender = renderDiff}
    } <-
    ask
  diff <- liftIO $ renderDiff color left right
  putPlainLn $ indented outputIndentation diff

toAssertionResult :: FixtureType a => EqualityResult a -> AssertionResult a
toAssertionResult EqualitySuccess = AssertionSuccess
toAssertionResult (EqualityFailure expected actual) = AssertionFailure $ SingleAssertionFailure $ AssertionFailureDiff expected actual

indentedKey :: String -> String
indentedKey = printf ("%-" ++ show outputIndentation ++ "s")
