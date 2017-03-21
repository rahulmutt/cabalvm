-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.Brancher
-- Copyright   :  (c) Andrea Vezzosi 2008
--                    Duncan Coutts 2011
--                    John Millikin 2012
--                    Rahul Muttineni 2017
-- License     :  BSD-like
--
-- Maintainer  :  cabal-devel@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- Helper functions for fetching package sources from SCM systems
-----------------------------------------------------------------------------

module Distribution.Client.Brancher (
  findUsableBranchers,
  forkPackage
  ) where

import Distribution.Verbosity
         ( Verbosity )
import System.Exit
         ( ExitCode(..) )
import qualified Distribution.PackageDescription as PD
import qualified Data.Map
import Distribution.Compat.Exception
        ( catchIO )
import Distribution.Client.Compat.Process
        ( readProcessWithExitCode )
import Control.Monad
         ( filterM, when )
import Distribution.Package
         ( PackageId, PackageName )
import Distribution.Text(display)
import System.FilePath
         ( (</>) )
import System.Directory
         ( doesDirectoryExist, doesFileExist )
import Distribution.Simple.Utils
         ( notice, die )
import System.Process
         ( rawSystem )
import Data.Maybe
         ( listToMaybe, mapMaybe )
import Data.List
         ( sortBy )
import Data.Ord
         ( comparing )

-- ------------------------------------------------------------
-- * Forking the source repository
-- ------------------------------------------------------------

data BranchCmd = BranchCmd (Verbosity -> FilePath -> IO ExitCode)

data Brancher = Brancher
    { brancherBinary :: String
    , brancherBuildCmd :: PD.SourceRepo -> Maybe BranchCmd
    }

-- | The set of all supported branch drivers.
allBranchers :: [(PD.RepoType, Brancher)]
allBranchers =
    [ (PD.Bazaar, branchBzr)
    , (PD.Darcs, branchDarcs)
    , (PD.Git, branchGit)
    , (PD.Mercurial, branchHg)
    , (PD.SVN, branchSvn)
    ]

-- | Find which usable branch drivers (selected from 'allBranchers') are
-- available and usable on the local machine.
--
-- Each driver's main command is run with @--help@, and if the child process
-- exits successfully, that brancher is considered usable.
findUsableBranchers :: IO (Data.Map.Map PD.RepoType Brancher)
findUsableBranchers = do
    let usable (_, brancher) = flip catchIO (const (return False)) $ do
         let cmd = brancherBinary brancher
         (exitCode, _, _) <- readProcessWithExitCode cmd ["--help"] ""
         return (exitCode == ExitSuccess)
    pairs <- filterM usable allBranchers
    return (Data.Map.fromList pairs)

-- | Fork a single package from a remote source repository to the local
-- file system.
forkPackage :: Verbosity
            -> Data.Map.Map PD.RepoType Brancher
               -- ^ Branchers supported by the local machine.
            -> FilePath
               -- ^ The directory in which new branches or repositories will
               -- be created.
            -> (Maybe PD.RepoKind)
               -- ^ Which repo to choose.
            -> PackageId
            -> [PD.SourceRepo]
               -- ^ The package to fork.
            -> IO ()
forkPackage verbosity branchers prefix kind pkgid' repos = do
    let pkgid = display pkgid'
        destdir = prefix

    destDirExists <- doesDirectoryExist destdir
    when destDirExists $ do
        die ("The directory " ++ show destdir ++ " already exists, not forking.")

    destFileExists  <- doesFileExist destdir
    when destFileExists $ do
        die ("A file " ++ show destdir ++ " is in the way, not forking.")

    case findBranchCmd branchers repos kind of
        Just (BranchCmd io) -> do
            exitCode <- io verbosity destdir
            case exitCode of
                ExitSuccess -> return ()
                ExitFailure _ -> die ("Couldn't fork package " ++ pkgid)
        Nothing -> case repos of
            [] -> die ("Package " ++ pkgid
                       ++ " does not have any source repositories.")
            _ -> die ("Package " ++ pkgid
                      ++ " does not have any usable source repositories.")

-- | Given a set of possible branchers, and a set of possible source
-- repositories, find a repository that is both 1) likely to be specific to
-- this source version and 2) is supported by the local machine.
findBranchCmd :: Data.Map.Map PD.RepoType Brancher -> [PD.SourceRepo]
                 -> (Maybe PD.RepoKind) -> Maybe BranchCmd
findBranchCmd branchers allRepos maybeKind = cmd where
    -- Sort repositories by kind, from This to Head to Unknown. Repositories
    -- with equivalent kinds are selected based on the order they appear in
    -- the Cabal description file.
    repos' = sortBy (comparing thisFirst) allRepos
    thisFirst r = case PD.repoKind r of
        PD.RepoThis -> 0 :: Int
        PD.RepoHead -> case PD.repoTag r of
            -- If the type is 'head' but the author specified a tag, they
            -- probably meant to create a 'this' repository but screwed up.
            Just _ -> 0
            Nothing -> 1
        PD.RepoKindUnknown _ -> 2

    -- If the user has specified the repo kind, filter out the repositories
    -- she's not interested in.
    repos = maybe repos' (\k -> filter ((==) k . PD.repoKind) repos') maybeKind

    repoBranchCmd repo = do
        t <- PD.repoType repo
        brancher <- Data.Map.lookup t branchers
        brancherBuildCmd brancher repo

    cmd = listToMaybe (mapMaybe repoBranchCmd repos)

-- | Branch driver for Bazaar.
branchBzr :: Brancher
branchBzr = Brancher "bzr" $ \repo -> do
    src <- PD.repoLocation repo
    let args dst = case PD.repoTag repo of
         Just tag -> ["branch", src, dst, "-r", "tag:" ++ tag]
         Nothing -> ["branch", src, dst]
    return $ BranchCmd $ \verbosity dst -> do
        notice verbosity ("bzr: branch " ++ show src)
        rawSystem "bzr" (args dst)

-- | Branch driver for Darcs.
branchDarcs :: Brancher
branchDarcs = Brancher "darcs" $ \repo -> do
    src <- PD.repoLocation repo
    let args dst = case PD.repoTag repo of
         Just tag -> ["get", src, dst, "-t", tag]
         Nothing -> ["get", src, dst]
    return $ BranchCmd $ \verbosity dst -> do
        notice verbosity ("darcs: get " ++ show src)
        rawSystem "darcs" (args dst)

-- | Branch driver for Git.
branchGit :: Brancher
branchGit = Brancher "git" $ \repo -> do
    src <- PD.repoLocation repo
    let branchArgs = ["--depth","1"] ++ case PD.repoBranch repo of
         Just b -> ["--branch", b]
         Nothing -> case PD.repoTag repo of
           Just t -> ["--branch", t]
           Nothing -> []
    return $ BranchCmd $ \verbosity dst -> do
        notice verbosity ("git: clone " ++ show src)
        rawSystem "git" (["clone", src, dst] ++ branchArgs)

-- | Branch driver for Mercurial.
branchHg :: Brancher
branchHg = Brancher "hg" $ \repo -> do
    src <- PD.repoLocation repo
    let branchArgs = case PD.repoBranch repo of
         Just b -> ["--branch", b]
         Nothing -> []
    let tagArgs = case PD.repoTag repo of
         Just t -> ["--rev", t]
         Nothing -> []
    let args dst = ["clone", src, dst] ++ branchArgs ++ tagArgs
    return $ BranchCmd $ \verbosity dst -> do
        notice verbosity ("hg: clone " ++ show src)
        rawSystem "hg" (args dst)

-- | Branch driver for Subversion.
branchSvn :: Brancher
branchSvn = Brancher "svn" $ \repo -> do
    src <- PD.repoLocation repo
    let args dst = ["checkout", src, dst]
    return $ BranchCmd $ \verbosity dst -> do
        notice verbosity ("svn: checkout " ++ show src)
        rawSystem "svn" (args dst)
