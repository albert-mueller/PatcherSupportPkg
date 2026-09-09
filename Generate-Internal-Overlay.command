#!/usr/bin/env python3

"""
Goal of this function is to create a Disk image holding only the files that are not committed to git
The purpose is to allow for internal developers to test their changes through the patcher more easily.

Resulting DMG will be placed in the root of the OpenCore-Legacy-Patcher repo for merging.
"""

import os
import sys
import shutil
import tempfile
import subprocess

from pathlib import Path


OCLP_DIRECTORY:  str = "../OpenCore-Legacy-Patcher"
OVERLAY_FOLDER:  str = "DortaniaInternalResources"
OVERLAY_DMG:     str = OVERLAY_FOLDER + ".dmg"
OVERLAY_VOLNAME: str = "Dortania Internal Resources"
DMG_ENCRYPTION:  str = "AES-256"
ENCRYPTION_FILE: str = "" # Replace with path to file containing the encryption password


class BuildError(Exception):
    """Raised for any recoverable failure, reported without a traceback."""


class GenerateInternalDiffDiskImage:

    def __init__(self) -> None:
        print("Generating internal diff disk image")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))

        files = self._find_binaries_to_add()
        if not files:
            print("  - No files to add")
            return
        self._prepare_workspace()
        self._generate_dmg(files)


    def _find_binaries_to_add(self) -> list:
        """
        Grab a list of all files that are not committed to git
        Exclude files that wouldn't be compatible with the patcher (ex. zip files)
        """
        uncommited_files = self._find_uncommited_files()
        uncommited_files = [file[1:-1] if file.startswith(("'", '"')) and file.endswith(("'", '"')) else file for file in uncommited_files]
        # Trailing slash required: "Universal-Binaries" alone, or a sibling such as
        # "Universal-Binaries-Old/", must not reach the path split in _generate_dmg.
        uncommited_files = [file for file in uncommited_files if file.startswith("Universal-Binaries/")]

        for extension in [".zip", ".dmg", ".pkg"]:
            uncommited_files = [file for file in uncommited_files if not file.endswith(extension)]

        # Directories are copied via their contents; a bare directory entry would
        # nest wrongly under the overlay folder.
        uncommited_files = [file for file in uncommited_files if not Path(file).is_dir()]

        return uncommited_files


    def _find_uncommited_files(self) -> list:
        """
        Grab a list of all files that are not committed to git

        Use git status to find uncommited files
        """
        uncommited_files = subprocess.run(
            ["/usr/bin/git", "status", "--porcelain"], capture_output=True, text=True)
        if uncommited_files.returncode != 0:
            print("  - Failed to find uncommited files")
            print(uncommited_files.stdout)
            print(uncommited_files.stderr)
            return []

        results = []
        for line in uncommited_files.stdout.split("\n"):
            if not line:
                continue

            index_status, worktree_status = line[0], line[1]

            # Deleted files no longer exist on disk; copying them would fail.
            if "D" in (index_status, worktree_status):
                continue

            path = line[3:]

            # Renames are reported as "old -> new"; only the new path exists.
            if "R" in (index_status, worktree_status) and " -> " in path:
                path = path.split(" -> ", 1)[1]

            results.append(path)

        return results


    def _legacy_find_uncommited_files(self) -> list:
        """
        Grab a list of all files that are not committed to git

        Legacy variant using ls-files. This is less reliable than using git status
        """
        uncommited_files = subprocess.run(
            [
                "/usr/bin/git", "ls-files", "--others", "--exclude-standard"
            ], capture_output=True, text=True)
        if uncommited_files.returncode != 0:
            print("  - Failed to find uncommited files")
            print(uncommited_files.stdout)
            print(uncommited_files.stderr)
            return []

        return [file for file in uncommited_files.stdout.split("\n") if file]


    def _prepare_workspace(self) -> None:
        """
        Remove old files and create a new workspace
        """
        print("  - Preparing workspace")

        if Path(OVERLAY_DMG).exists():
            subprocess.run(["/bin/rm", OVERLAY_DMG])

        if Path(OVERLAY_FOLDER).exists():
            subprocess.run(["/bin/rm", "-rf", OVERLAY_FOLDER])

        subprocess.run(["/bin/mkdir", OVERLAY_FOLDER])


    def _fetch_encryption_password(self) -> str:
        """
        Return the encryption password for the DMG
        """
        if not ENCRYPTION_FILE:
            return "password"
        password_file = Path(ENCRYPTION_FILE).expanduser()
        if not password_file.exists() or not password_file.is_file():
            return "password"
        return password_file.read_text().strip()


    def _run(self, arguments: list, description: str, **kwargs) -> None:
        """
        Run a command and surface its failure instead of silently continuing
        """
        result = subprocess.run(arguments, capture_output=True, text=True, **kwargs)
        if result.returncode != 0:
            for stream in (result.stdout, result.stderr):
                for line in (stream or "").splitlines():
                    if line.strip():
                        print(f"      {line}")
            raise BuildError(f"Failed to {description} (exit {result.returncode})")


    def _generate_dmg(self, files: list) -> None:
        """
        Copy files to the workspace and generate the DMG
        """
        print("  - Copying files")
        for file in files:
            print(f"    - {file}")
            src_path = Path(file)
            dst_path = Path(OVERLAY_FOLDER) / str(src_path).split("Universal-Binaries/", 1)[1]
            if not Path(dst_path.parent).exists():
                subprocess.run(["/bin/mkdir", "-p", dst_path.parent])
            subprocess.run(["/bin/cp", "-a", src_path, dst_path])

        # Temporary image lives outside the repo so a failed run cannot strand it.
        tmp_directory = tempfile.mkdtemp(prefix="psp-overlay-")
        tmp_dmg       = os.path.join(tmp_directory, "tmp.dmg")

        try:
            print("  - Generating tmp DMG")
            self._run([
                "/usr/bin/hdiutil", "create",
                "-srcfolder", OVERLAY_FOLDER, tmp_dmg,
                "-volname", OVERLAY_VOLNAME,
                "-fs", "APFS",
                "-ov",
                "-format", "UDRO"
            ], "create the temporary disk image")

            print("  - Converting to encrypted DMG")
            # Passphrase goes over stdin, not argv: a -passphrase value is visible
            # in ps output to every other user on the machine while hdiutil runs.
            # Encryption method is stated explicitly so the following flag cannot
            # be consumed as the method name. No trailing newline is added:
            # -stdinpass consumes stdin verbatim and would fold it into the
            # passphrase.
            self._run(
                ["/usr/bin/hdiutil", "convert",
                 "-format", "ULMO", tmp_dmg,
                 "-o", OVERLAY_DMG,
                 "-encryption", DMG_ENCRYPTION,
                 "-stdinpass",
                 "-ov"
                ],
                "convert the disk image",
                input=self._fetch_encryption_password()
            )
        finally:
            shutil.rmtree(tmp_directory, ignore_errors=True)

        if Path(OCLP_DIRECTORY).exists():
            print("  - Moving DMG")
            if Path(OCLP_DIRECTORY, OVERLAY_DMG).exists():
                subprocess.run(["/bin/rm", f"{OCLP_DIRECTORY}/{OVERLAY_DMG}"])
            subprocess.run(["/bin/mv", OVERLAY_DMG, f"{OCLP_DIRECTORY}/{OVERLAY_DMG}"])

        print("  - Cleaning up")
        subprocess.run(["/bin/rm", "-rf", OVERLAY_FOLDER])


if __name__ == "__main__":
    try:
        GenerateInternalDiffDiskImage()
    except BuildError as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
