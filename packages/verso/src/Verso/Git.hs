{- | The git operations behind RFC-0032 page versioning, layered over
'MicroHttp.Process'. The document tree is a git repository in place: a Publish or
a structural operation records a commit, and a page's revision history is read
back with @git log@.

Every git invocation runs as @git -C \<root\> ...@ with the tree root and all
paths passed as exact argument-vector elements (no shell, no quoting), so paths
containing spaces are safe. Author identity is supplied per-commit with git's own
@-c user.name=@/@-c user.email=@ options rather than relying on ambient git
configuration, so commits succeed even in a repository that has none configured
and are always attributed to the acting author.

This module is deliberately configuration-agnostic: callers pass an 'Identity'
(built from config by 'Verso.Identity'\/'Verso.Config'); it knows only git.
-}
module Verso.Git (
    Identity (..),
    Revision (..),
    CommitResult (..),
    RepoInit (..),
    gitAvailable,
    ensureRepository,
    commitPaths,
    commitAll,
    logForPath,
    withDiffCapture,
    withFileAtRevisionCapture,
) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Process as Process
import qualified MicroHttp.Stream as Stream
import qualified MicroHttp.Utf8 as Utf8
import qualified System.Directory as Directory
import qualified System.Exit as Exit

-- | A commit author: the display name and email written into a git commit and shown in revision history.
data Identity = Identity
    { identityName :: String
    , identityEmail :: String
    }
    deriving (Eq, Show)

-- | One entry of a page's revision history, parsed from a @git log@ line.
data Revision = Revision
    { revShort :: String
    -- ^ Abbreviated commit hash.
    , revHash :: String
    -- ^ Full commit hash.
    , revTimestamp :: String
    -- ^ Author date in strict ISO-8601 form.
    , revAuthor :: String
    -- ^ Author display name.
    , revSubject :: String
    -- ^ Commit subject line (the auto-generated message).
    }
    deriving (Eq, Show)

-- | The outcome of an attempted commit.
data CommitResult
    = -- | A commit was created; carries its abbreviated hash.
      Committed String
    | -- | Nothing was staged (for example a Publish whose draft matched the published page); no commit made.
      NothingToCommit
    | -- | The commit failed; carries the captured stderr for logging.
      CommitFailed String
    deriving (Eq, Show)

-- | Whether 'ensureRepository' had to create the repository or found one already present.
data RepoInit = Initialised | AlreadyPresent
    deriving (Eq, Show)

-- | Runs @git -C \<root\> \<args\>@ with no stdin and no separate working directory (the @-C@ sets it).
git :: FilePath -> [String] -> IO Process.ProcResult
git root args = Process.runProcess "git" ("-C" : root : args) Nothing Nothing

-- | Whether the @git@ executable is invokable at all (@git --version@ succeeds). Used at startup.
gitAvailable :: IO Bool
gitAvailable = do
    res <- Process.runProcess "git" ["--version"] Nothing Nothing
    pure (Process.procExit res == Exit.ExitSuccess)

{- | Ensures the tree root is a git repository: if it already has a @.git@, uses
it unchanged; otherwise @git init@s it and records an initial import commit of the
current tree state attributed to the supplied import identity. Returns which path
was taken (for startup logging).
-}
ensureRepository :: FilePath -> Identity -> IO RepoInit
ensureRepository root importer = do
    present <- Directory.doesDirectoryExist (root ++ "/.git")
    if present
        then pure AlreadyPresent
        else do
            _ <- git root ["init"]
            _ <- git root ["add", "-A"]
            _ <- commitStaged root importer "Import existing document tree"
            pure Initialised

{- | Stages the given tree-relative paths and commits them with the author
identity and message. Reports 'NothingToCommit' when staging leaves no change
(so an unchanged Publish does not create an empty revision), or 'CommitFailed'
with stderr on error.
-}
commitPaths :: FilePath -> Identity -> String -> [FilePath] -> IO CommitResult
commitPaths root author message paths = do
    mapM_ (\p -> git root ["add", "--", p]) paths
    commitStaged root author message

{- | Stages every change in the tree (@git add -A@) and commits it as one
revision. This is the "commit the resulting tree state" form used by structural
operations, which can touch a page plus its sidecar metadata, assets, and (for
moves) rewritten referrers and listings. Returns 'NothingToCommit' when nothing
changed.
-}
commitAll :: FilePath -> Identity -> String -> IO CommitResult
commitAll root author message = do
    _ <- git root ["add", "-A"]
    commitStaged root author message

{- | Commits whatever is currently staged, attributed to @author@. Detects an
empty stage via @git diff --cached --quiet@ (exit 0 means no staged changes) so a
no-op commit is reported as 'NothingToCommit' rather than failing.
-}
commitStaged :: FilePath -> Identity -> String -> IO CommitResult
commitStaged root author message = do
    staged <- git root ["diff", "--cached", "--quiet"]
    case Process.procExit staged of
        Exit.ExitSuccess -> pure NothingToCommit
        _ -> do
            res <-
                git
                    root
                    [ "-c"
                    , "user.name=" ++ identityName author
                    , "-c"
                    , "user.email=" ++ identityEmail author
                    , "commit"
                    , "-m"
                    , message
                    ]
            case Process.procExit res of
                Exit.ExitSuccess -> do
                    headRes <- git root ["rev-parse", "--short", "HEAD"]
                    pure (Committed (chomp (BS.unpack (Process.procOut headRes))))
                _ -> pure (CommitFailed (Utf8.decodeBytes (Process.procErr res)))

{- | The revision history of a tree-relative page, newest first, following the
page across renames\/moves (@git log --follow@). Returns @[]@ when the path has
no history or the command fails (for example outside a repository). The log is
folded from its capture one line at a time (RFC-0043): a long history is never
held whole.
-}
logForPath :: FilePath -> FilePath -> IO [Revision]
logForPath root path =
    Process.withCapture "git" ["-C", root, "log", "--follow", "--format=" ++ logFormat, "--", path] Nothing Nothing $ \cap ->
        case Process.captureExit cap of
            Exit.ExitSuccess -> do
                folded <- Stream.foldFileLines collect [] (Process.captureOut cap)
                pure (either (const []) reverse folded)
            _ -> pure []
  where
    collect revs line
        | BS.null line = pure revs
        | otherwise = pure (parseRevision line : revs)

{- | Runs @git diff@ between two revisions of a page and hands the capture to
@consume@ under 'Process.withCaptureHandoff' (RFC-0040, RFC-0043): the consumer
streams the stdout capture (a response body that removes it when done) or
finishes with it, and reads the exit code from 'Process.captureExit'. The diff
never enters the heap.
-}
withDiffCapture :: FilePath -> String -> String -> FilePath -> (Process.ProcCapture -> IO (Process.Handoff a)) -> IO a
withDiffCapture root fromRev toRev path =
    Process.withCaptureHandoff "git" ["-C", root, "diff", fromRev, toRev, "--", path] Nothing Nothing

{- | Runs @git show \<rev\>:\<path\>@ and hands the capture to @consume@ under
'Process.withCaptureHandoff': a page's exact bytes at a revision, streamed or
copied into place without materialising them. @git show@ exits non-zero when the
path did not exist at that revision, which the consumer reads from
'Process.captureExit'.
-}
withFileAtRevisionCapture :: FilePath -> String -> FilePath -> (Process.ProcCapture -> IO (Process.Handoff a)) -> IO a
withFileAtRevisionCapture root rev path =
    Process.withCaptureHandoff "git" ["-C", root, "show", rev ++ ":" ++ path] Nothing Nothing

-- | The @--format@ string: fields separated by a unit-separator byte that cannot appear in the values.
logFormat :: String
logFormat = "%h%x1f%H%x1f%aI%x1f%an%x1f%s"

-- | Parses one log line of unit-separated fields into a 'Revision'; missing fields default to empty.
parseRevision :: BS.ByteString -> Revision
parseRevision line =
    case map Utf8.decodeBytes (BS.split '\031' line) of
        (h : full : ts : author : rest) -> Revision h full ts author (joinSubject rest)
        _ -> Revision "" "" "" "" (Utf8.decodeBytes line)
  where
    -- the subject is the final field; rejoin defensively in case a value ever held the separator
    joinSubject = foldr (\a b -> if null b then a else a ++ "\031" ++ b) ""

-- | Drops trailing carriage returns and newlines (git command output is newline-terminated).
chomp :: String -> String
chomp = reverse . dropWhile isEol . reverse
  where
    isEol c = c == '\n' || c == '\r'
