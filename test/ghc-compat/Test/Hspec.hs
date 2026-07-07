module Test.Hspec (
    SpecM,
    Spec,
    describe,
    context,
    it,
    Expectation,
    expect,
    shouldBe,
    shouldReturn,
    hspec,
) where

import qualified Control.Exception as Exception
import Control.Monad (ap, when)
import Data.List (intercalate)
import Data.Typeable (Typeable)
import System.Exit (exitFailure)

data SpecM a = SpecM a [SpecTree]

type Spec = SpecM ()

data SpecTree
    = SpecGroup String Spec
    | SpecExample String (IO Result)

data Result
    = Success
    | Failure String
    deriving (Eq, Show)

data Summary = Summary Int Int

type Expectation = IO ()

newtype ExpectationFailure = ExpectationFailure String
    deriving (Eq, Show, Typeable)

instance Exception.Exception ExpectationFailure

instance Functor SpecM where
    fmap f (SpecM value trees) = SpecM (f value) trees

instance Applicative SpecM where
    pure value = SpecM value []
    (<*>) = ap

instance Monad SpecM where
    SpecM value trees >>= f =
        case f value of
            SpecM next moreTrees -> SpecM next (trees ++ moreTrees)

instance Semigroup Summary where
    Summary examples failures <> Summary moreExamples moreFailures =
        Summary (examples + moreExamples) (failures + moreFailures)

instance Monoid Summary where
    mempty = Summary 0 0

describe :: String -> Spec -> Spec
describe label = add . SpecGroup label

context :: String -> Spec -> Spec
context = describe

it :: String -> Expectation -> Spec
it label = add . SpecExample label . evaluateExpectation

expect :: String -> Bool -> Expectation
expect label condition =
    if condition
        then return ()
        else Exception.throwIO (ExpectationFailure label)

-- The same fixity as the real hspec: without it these default to infixl 9 and
-- bind tighter than (++), flipping the parse of `x `shouldBe` a ++ b`.
infix 1 `shouldBe`, `shouldReturn`

shouldBe :: (Show a, Eq a) => a -> a -> Expectation
actual `shouldBe` expected =
    expect ("expected: " ++ show expected ++ "\n but got: " ++ show actual) (actual == expected)

shouldReturn :: (Show a, Eq a) => IO a -> a -> Expectation
action `shouldReturn` expected = action >>= (`shouldBe` expected)

hspec :: Spec -> IO ()
hspec spec = do
    Summary total failures <- runSpec spec
    putStrLn (show total ++ " example(s), " ++ show failures ++ " failure(s)")
    when (failures /= 0) exitFailure

add :: SpecTree -> SpecM ()
add tree = SpecM () [tree]

runSpec :: Spec -> IO Summary
runSpec = runTrees []
  where
    runTrees labels (SpecM () trees) =
        mconcat <$> mapM (runTree labels) trees

    runTree labels tree =
        case tree of
            SpecGroup label spec ->
                runTrees (label : labels) spec
            SpecExample label action -> do
                putStr $ "/" ++ (intercalate "/" . reverse) (label : labels) ++ "/ "
                result <- action
                case result of
                    Success -> do
                        putStrLn "OK"
                        return (Summary 1 0)
                    Failure err -> do
                        putStrLn "FAILED"
                        putStrLn err
                        return (Summary 1 1)

evaluateExpectation :: Expectation -> IO Result
evaluateExpectation action =
    Exception.catches
        (action >> return Success)
        [ Exception.Handler $ \err -> Exception.throwIO (err :: Exception.AsyncException)
        , Exception.Handler $ \(ExpectationFailure err) -> return (Failure err)
        , Exception.Handler $ \err -> return (Failure ("*** Exception: " ++ show (err :: Exception.SomeException)))
        ]
