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
    diffBetween,
    showFileAtRevision,
) where

import qualified Data.ByteString.Char8 as BS
import qualified MicroHttp.Process as Process
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
revision. This is the "commit the resulting tree state" form used by Publish and
structural operations, which can each touch a page plus its sidecar metadata,
assets, and (for moves) rewritten referrers and listings. Returns
'NothingToCommit' when nothing changed.
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
                _ -> pure (CommitFailed (BS.unpack (Process.procErr res)))

{- | The revision history of a tree-relative page, newest first, following the
page across renames\/moves (@git log --follow@). Returns @[]@ when the path has
no history or the command fails (for example outside a repository).
-}
logForPath :: FilePath -> FilePath -> IO [Revision]
logForPath root path = do
    res <- git root ["log", "--follow", "--format=" ++ logFormat, "--", path]
    case Process.procExit res of
        Exit.ExitSuccess -> pure (parseLog (Process.procOut res))
        _ -> pure []

{- | The unified diff of a page between two revisions, as git's standard
line-based diff text, for the caller to render with per-line add\/remove
highlighting. Empty when the command fails.
-}
diffBetween :: FilePath -> String -> String -> FilePath -> IO String
diffBetween root fromRev toRev path = do
    res <- git root ["diff", fromRev, toRev, "--", path]
    pure (BS.unpack (Process.procOut res))

{- | A page's exact content at a revision (@git show \<rev\>:\<path\>@), as bytes
so it round-trips losslessly; empty bytes when the path did not exist there or the
command fails. Used by rollback.
-}
showFileAtRevision :: FilePath -> String -> FilePath -> IO BS.ByteString
showFileAtRevision root rev path = do
    res <- git root ["show", rev ++ ":" ++ path]
    pure (case Process.procExit res of Exit.ExitSuccess -> Process.procOut res; _ -> BS.empty)

-- | The @--format@ string: fields separated by a unit-separator byte that cannot appear in the values.
logFormat :: String
logFormat = "%h%x1f%H%x1f%aI%x1f%an%x1f%s"

-- | Parses @git log@ output: one revision per line, fields split on the unit-separator byte (@0x1f@).
parseLog :: BS.ByteString -> [Revision]
parseLog = map parseRevision . filter (not . BS.null) . BS.lines

-- | Parses one log line of unit-separated fields into a 'Revision'; missing fields default to empty.
parseRevision :: BS.ByteString -> Revision
parseRevision line =
    case map BS.unpack (BS.split '\031' line) of
        (h : full : ts : author : rest) -> Revision h full ts author (joinSubject rest)
        _ -> Revision "" "" "" "" (BS.unpack line)
  where
    -- the subject is the final field; rejoin defensively in case a value ever held the separator
    joinSubject = foldr (\a b -> if null b then a else a ++ "\031" ++ b) ""

-- | Drops trailing carriage returns and newlines (git command output is newline-terminated).
chomp :: String -> String
chomp = reverse . dropWhile isEol . reverse
  where
    isEol c = c == '\n' || c == '\r'
