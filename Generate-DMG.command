#!/usr/bin/env python3
"""
Build PatcherSupportPkg Disk Image for local testing.

DMG is password-encrypted but NOT signed.

Relative --source and --output paths are resolved against the directory
containing this script, not the caller's working directory.
"""

import os
import sys
import shutil
import argparse
import tempfile
import subprocess


UB_DIRECTORY:   str = "Universal-Binaries"
DMG_NAME:       str = "Universal-Binaries.dmg"
DMG_VOLNAME:    str = "OpenCore Patcher Resources (Root Patching)"
DMG_FORMAT:     str = "UDRO"
DMG_ENCRYPTION: str = "AES-256"
DMG_PASSPHRASE: str = "password"

# Floor matches upstream's fixed -megabytes value, so a low measurement can
# never produce an image smaller than the one known to work.
DMG_MEGABYTES_FLOOR: int   = 4096
# Covers HFS+ catalog growth and hdiutil's own slack. Universal-Binaries is
# mostly small files, where per-file block rounding dominates.
DMG_SIZE_HEADROOM:   float = 1.30
# Allocation unit used for the per-file rounding in _measure_source.
FS_BLOCK_SIZE:       int   = 4096


class BuildError(Exception):
    """Raised for any recoverable build failure, reported without a traceback."""


class GenerateDiskImage:

    def __init__(self,
                 source:     str = UB_DIRECTORY,
                 output:     str = DMG_NAME,
                 volname:    str = DMG_VOLNAME,
                 passphrase: str = DMG_PASSPHRASE,
                 megabytes:  int = None
                 ) -> None:
        self._source     = source
        self._output     = output
        self._volname    = volname
        self._passphrase = passphrase
        self._megabytes  = megabytes


    def build(self) -> None:
        print("Generating DMG (test build, no signing)")

        self._check_host()
        self._set_working_directory()
        self._validate_source()
        self._strip_extended_attributes()
        self._remove_ds_store()

        # Temporary image lives in its own directory so a failed run
        # cannot leave a multi-gigabyte file behind in the repo.
        tmp_directory = tempfile.mkdtemp(prefix="psp-dmg-")
        tmp_dmg       = os.path.join(tmp_directory, "tmp.dmg")

        try:
            self._create_dmg(tmp_dmg)
            self._convert_dmg(tmp_dmg)
        finally:
            shutil.rmtree(tmp_directory, ignore_errors=True)

        print(f"  - Done. Output: {os.path.abspath(self._output)}")


    def _check_host(self) -> None:
        if sys.platform != "darwin":
            raise BuildError("hdiutil is only available on macOS")


    def _set_working_directory(self) -> None:
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        print("  - Working directory set")


    def _validate_source(self) -> None:
        if not os.path.isdir(self._source):
            raise BuildError(
                f"Source directory not found: {os.path.abspath(self._source)}"
            )


    def _strip_extended_attributes(self) -> None:
        print("  - Stripping extended attributes")
        result = subprocess.run(
            ["/usr/bin/xattr", "-rc", self._source],
            capture_output=True
        )
        # xattr returns non-zero if it failed on any single file, so a partial
        # strip is reported rather than silently accepted.
        if result.returncode != 0:
            print(f"    - WARNING: xattr exited {result.returncode}, "
                  "some attributes may remain")
            for line in result.stderr.decode(errors="replace").splitlines():
                if line.strip():
                    print(f"      {line}")


    def _remove_ds_store(self) -> None:
        print("  - Removing .DS_Store files")
        result = subprocess.run(
            ["/usr/bin/find", self._source, "-name", ".DS_Store", "-delete"],
            capture_output=True
        )
        if result.returncode != 0:
            print(f"    - WARNING: find exited {result.returncode}")
            for line in result.stderr.decode(errors="replace").splitlines():
                if line.strip():
                    print(f"      {line}")


    def _measure_source(self) -> int:
        """
        Return the image size in MB needed to hold the source folder.

        Sums apparent file sizes rounded up to a filesystem block, so the
        per-file overhead that dominates a tree of many small binaries is
        accounted for. Apparent size is used deliberately: if the source sits
        on a compressed APFS volume, allocated size under-reports what an
        uncompressed HFS+ target needs.
        """
        total_bytes = 0
        file_count  = 0

        for directory, _, filenames in os.walk(self._source):
            # Directory entries themselves consume catalog space.
            total_bytes += FS_BLOCK_SIZE
            for filename in filenames:
                path = os.path.join(directory, filename)
                try:
                    stats = os.lstat(path)
                except OSError:
                    continue
                # Symlinks store their target string, not the payload.
                if os.path.islink(path):
                    total_bytes += FS_BLOCK_SIZE
                    continue
                blocks = -(-stats.st_size // FS_BLOCK_SIZE)  # ceiling division
                total_bytes += blocks * FS_BLOCK_SIZE
                file_count  += 1

        megabytes = int((total_bytes * DMG_SIZE_HEADROOM) // (1024 * 1024)) + 1
        megabytes = max(megabytes, DMG_MEGABYTES_FLOOR)

        print(f"    - {file_count} files, sizing image at {megabytes} MB")
        return megabytes


    def _create_dmg(self, tmp_dmg: str) -> None:
        print("  - Creating temporary DMG")

        # An explicit size is required. hdiutil's automatic sizing measures the
        # source's apparent content and under-allocates on a tree of this
        # shape; the copy then runs out of space partway through WITHOUT
        # hdiutil reliably exiting non-zero, producing an image that mounts
        # cleanly but is missing files. The temporary image is discarded right
        # after conversion and ULMO stores only allocated blocks, so an
        # oversized temporary costs scratch space for the length of the run and
        # nothing in the output.
        megabytes = (self._megabytes
                     if self._megabytes is not None
                     else self._measure_source())

        arguments = [
            "/usr/bin/hdiutil", "create",
            "-srcfolder", self._source,
            "-volname",   self._volname,
            # HFS+, matching upstream. APFS images carry larger container
            # overhead and are not what OCLP root patching is tested against.
            "-fs",        "HFS+",
            "-format",    DMG_FORMAT,
            "-megabytes", str(megabytes),
            "-ov",
        ]

        arguments.append(tmp_dmg)

        self._run(arguments, "create the temporary disk image")

        self._verify_dmg(tmp_dmg)


    def _verify_dmg(self, tmp_dmg: str) -> None:
        """
        Compare file counts between the source and the built image.

        This is the check that catches a short copy, since hdiutil's exit code
        does not.
        """
        print("  - Verifying file count")

        expected = sum(len(files) for _, _, files in os.walk(self._source))

        mountpoint = tempfile.mkdtemp(prefix="psp-verify-")
        try:
            self._run(
                ["/usr/bin/hdiutil", "attach", tmp_dmg,
                 "-mountpoint", mountpoint, "-nobrowse", "-readonly"],
                "attach the temporary disk image",
                capture_output=True
            )
            try:
                actual = sum(len(files) for _, _, files in os.walk(mountpoint))
            finally:
                subprocess.run(
                    ["/usr/bin/hdiutil", "detach", mountpoint, "-quiet"],
                    capture_output=True
                )
        finally:
            shutil.rmtree(mountpoint, ignore_errors=True)

        if actual < expected:
            raise BuildError(
                f"Image holds {actual} files but the source has {expected}. "
                "The copy was truncated; raise --megabytes and retry."
            )

        print(f"    - {actual} files present")


    def _convert_dmg(self, tmp_dmg: str) -> None:
        print("  - Converting to encrypted ULMO DMG")

        # Removed up front: hdiutil will not overwrite an image that is
        # currently attached, and this surfaces that as a clearer failure.
        if os.path.exists(self._output):
            os.remove(self._output)

        self._run(
            [
                "/usr/bin/hdiutil", "convert", tmp_dmg,
                "-format",     "ULMO",
                # Method stated explicitly so it cannot be confused with the
                # flag that follows it.
                "-encryption", DMG_ENCRYPTION,
                "-stdinpass",
                "-o",          self._output,
                "-ov",
            ],
            "convert the disk image",
            # No trailing newline: -stdinpass consumes stdin verbatim, so a
            # newline would become part of the passphrase itself.
            input=self._passphrase.encode()
        )


    def _run(self, arguments: list, description: str, **kwargs) -> None:
        result = subprocess.run(arguments, **kwargs)
        if result.returncode != 0:
            raise BuildError(
                f"Failed to {description} (hdiutil exited {result.returncode}). "
                "If a previous image is still attached, detach it and retry."
            )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build the PatcherSupportPkg disk image for local testing."
    )
    parser.add_argument("--source",     default=UB_DIRECTORY,
                        help=f"Folder to package (default: {UB_DIRECTORY})")
    parser.add_argument("--output",     default=DMG_NAME,
                        help=f"Output image path (default: {DMG_NAME})")
    parser.add_argument("--volname",    default=DMG_VOLNAME,
                        help="Mounted volume name")
    parser.add_argument("--passphrase",
                        default=os.environ.get("PSP_DMG_PASSPHRASE", DMG_PASSPHRASE),
                        help="Encryption passphrase; also read from "
                             "PSP_DMG_PASSPHRASE (default: the test passphrase)")
    parser.add_argument("--megabytes",  type=int, default=None,
                        help="Fixed image size in MB; omit to measure the source")

    arguments = parser.parse_args()

    try:
        GenerateDiskImage(
            source     = arguments.source,
            output     = arguments.output,
            volname    = arguments.volname,
            passphrase = arguments.passphrase,
            megabytes  = arguments.megabytes
        ).build()
    except BuildError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        return 130

    return 0


if __name__ == "__main__":
    sys.exit(main())
