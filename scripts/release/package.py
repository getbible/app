#!/usr/bin/env python3
"""Package already-built Flutter outputs without downloading tools or signing.

One metadata document supplies every Flutter build's --build-name/--build-number.
Each target is staged independently and published only after all of its required
packages succeed. Native tools (dpkg, Inno Setup, ditto/hdiutil) remain explicit
host prerequisites. Run `python scripts/release/package.py --help` for the CLI.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile


ROOT = Path(__file__).resolve().parents[2]
APP = "getbible-live"
MAINTAINER = "Llewellyn van der Merwe <5607939+Llewellynvdm@users.noreply.github.com>"


class PackagingError(Exception):
    """A missing prerequisite or invalid input; no target is published."""


def run(args: list[str | Path], *, cwd: Path | None = None) -> str:
    result = subprocess.run(
        [str(arg) for arg in args], cwd=cwd, text=True, capture_output=True,
        check=False,
    )
    if result.returncode:
        raise PackagingError(
            f"Command failed ({result.returncode}): {args[0]}\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return result.stdout.strip()


def tool(name: str) -> Path:
    executable = shutil.which(name)
    if not executable:
        raise PackagingError(f"Required packaging tool is missing: {name}")
    return Path(executable)


def require(path: Path, *, directory: bool = False) -> Path:
    valid = path.is_dir() if directory else path.is_file() and path.stat().st_size > 0
    if not valid:
        raise PackagingError(f"Required {'directory' if directory else 'file'} missing or empty: {path}")
    return path


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


@dataclass(frozen=True)
class ReleaseMetadata:
    release_version: str
    version_name: str
    build_number: int
    channel: str
    version: str
    artifact_version: str
    git_sha: str
    source_date_epoch: int
    dirty: bool
    schema_version: int = 1

    @classmethod
    def create(cls, repo: Path, build_number: int | None) -> ReleaseMetadata:
        pubspec = require(repo / "pubspec.yaml").read_text(encoding="utf-8")
        number = r"(?:0|[1-9]\d*)"
        match = re.search(
            rf"^version:\s*((({number})\.({number})\.({number}))(?:-(alpha|beta|rc)\.([1-9]\d*))?)\+([1-9]\d*)\s*$",
            pubspec, re.M,
        )
        if not match:
            raise PackagingError("pubspec.yaml version must be MAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]+BUILD, without leading zeros")
        release_version, version_name, _, _, _, channel, _, configured_build = match.groups()
        build = int(configured_build)
        if build_number is not None and build_number != build:
            raise PackagingError("pubspec.yaml is the version source of truth; --build-number must equal its configured build number")
        if build < 1 or max(build, *(int(n) for n in version_name.split("."))) > 65535:
            raise PackagingError("Version components and build number must fit Windows' 16-bit version fields (1–65535 for build)")
        return cls(
            release_version, version_name, build, channel or "stable", f"{release_version}+{build}",
            f"{release_version}-build.{build}", run(["git", "rev-parse", "HEAD"], cwd=repo),
            int(run(["git", "show", "-s", "--format=%ct", "HEAD"], cwd=repo)),
            bool(run(["git", "status", "--porcelain"], cwd=repo)),
        )

    @classmethod
    def load(cls, path: Path, repo: Path) -> ReleaseMetadata:
        try:
            metadata = cls(**json.loads(require(path).read_text(encoding="utf-8")))
        except (TypeError, ValueError) as error:
            raise PackagingError(f"Invalid release metadata: {error}") from error
        expected = cls.create(repo, metadata.build_number)
        for field in ("release_version", "version_name", "channel", "version", "artifact_version", "git_sha", "source_date_epoch", "schema_version"):
            if getattr(metadata, field) != getattr(expected, field):
                raise PackagingError(f"Release metadata {field} differs from this checkout; regenerate metadata and rebuild")
        if type(metadata.dirty) is not bool or type(metadata.build_number) is not int:
            raise PackagingError("Invalid release metadata types")
        return metadata


def validate_tree(source: Path) -> None:
    """Reject external symlinks and special files before staging any bundle."""
    require(source, directory=True)
    root = source.resolve()
    for path in source.rglob("*"):
        if path.is_symlink():
            if not path.resolve().is_relative_to(root) or not path.exists():
                raise PackagingError(f"Bundle has an external or broken symlink: {path}")
        elif not path.is_file() and not path.is_dir():
            raise PackagingError(f"Unsupported bundle entry: {path}")


def copy_tree(source: Path, destination: Path) -> None:
    validate_tree(source)
    shutil.copytree(source, destination, symlinks=True)


def archive_zip(source: Path, output: Path, epoch: int, *, parent: bool = True) -> None:
    """Normalize ZIP metadata while preserving executable bits and symlinks."""
    validate_tree(source)
    date = time.gmtime(max(epoch, 315532800))[:6]
    base = source.parent if parent else source
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(source.rglob("*")):
            relative = path.relative_to(base).as_posix()
            mode = path.lstat().st_mode
            entry = zipfile.ZipInfo(relative + ("/" if path.is_dir() and not path.is_symlink() else ""), date)
            entry.create_system = 3
            entry.external_attr = mode << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            if path.is_symlink():
                archive.writestr(entry, os.readlink(path).encode("utf-8"))
            elif path.is_dir():
                archive.writestr(entry, b"")
            else:
                with path.open("rb") as data, archive.open(entry, "w") as target:
                    shutil.copyfileobj(data, target)


def archive_tar(source: Path, output: Path, epoch: int) -> None:
    validate_tree(source)

    def normalize(entry: tarfile.TarInfo) -> tarfile.TarInfo:
        entry.uid = entry.gid = 0
        entry.uname = entry.gname = "root"
        entry.mtime = epoch
        return entry

    with output.open("wb") as destination, gzip.GzipFile(filename="", fileobj=destination, mode="wb", mtime=epoch) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
            archive.add(source, arcname=source.name, filter=normalize)


@dataclass(frozen=True)
class PackageContext:
    repo: Path
    metadata: ReleaseMetadata
    staging: Path
    target: str
    arch: str
    input: Path | None
    base_href: str
    signing_mode: str = "unsigned"
    sign_hook: Path | None = None
    apksigner: Path | None = None


class Packager:
    signing = "unsigned"
    installability = "desktop installation"

    def __init__(self, context: PackageContext):
        self.context = context
        self.artifacts: list[tuple[Path, str]] = []
        self.arch = context.arch

    @property
    def prefix(self) -> str:
        signed = "-signed" if self.context.signing_mode == "distribution" and not self.context.target.endswith("-signed") else ""
        return f"{APP}-{self.context.metadata.artifact_version}-{self.context.target}-{self.arch}{signed}"

    def output(self, suffix: str, role: str) -> Path:
        path = self.context.staging / (self.prefix + suffix)
        self.artifacts.append((path, role))
        return path

    def bundle(self, source: Path, name: str | None = None) -> Path:
        target = self.context.staging / "work" / (name or self.prefix)
        target.parent.mkdir(parents=True, exist_ok=True)
        copy_tree(source, target)
        return target

    def build(self) -> None:
        raise NotImplementedError

    def manifest(self) -> dict:
        return {
            **asdict(self.context.metadata), "target": self.context.target,
            "architecture": self.arch, "signing": self.signing,
            "distribution_signed": self.context.signing_mode == "distribution" or self.context.target.endswith("-signed"),
            "installability": self.installability,
            "artifacts": [
                {"file": path.name, "role": role, "bytes": require(path).stat().st_size, "sha256": sha256(path)}
                for path, role in self.artifacts
            ],
        }


class LinuxPackager(Packager):
    signing = "not signed"

    def build(self) -> None:
        if self.arch not in ("x64", "arm64"):
            raise PackagingError("Linux packaging requires --arch x64 or arm64")
        repo, metadata = self.context.repo, self.context.metadata
        source = self.context.input or repo / f"build/linux/{self.arch}/release/bundle"
        bundle = self.bundle(source)
        executable = require(bundle / "getbible_life")
        header = executable.read_bytes()[:20]
        if len(header) < 20 or header[:5] != b"\x7fELF\x02" or header[5] != 1:
            raise PackagingError("Linux executable must be a little-endian 64-bit ELF")
        if struct.unpack_from("<H", header, 18)[0] != {"x64": 62, "arm64": 183}[self.arch]:
            raise PackagingError("Linux executable architecture differs from --arch")
        if not executable.stat().st_mode & stat.S_IXUSR:
            raise PackagingError("Linux executable is not executable")
        require(bundle / "data/icudtl.dat")
        require(bundle / "data/flutter_assets", directory=True)
        require(bundle / "lib/libflutter_linux_gtk.so")
        require(bundle / "lib/libapp.so")
        shutil.copy2(require(repo / "LICENSE"), bundle / "LICENSE")
        write_json(bundle / "release-metadata.json", asdict(metadata))
        archive_tar(bundle, self.output(".tar.gz", "portable bundle"), metadata.source_date_epoch)

        deb = self.context.staging / "work/debian"
        app = deb / "opt/getbible-live"
        app.parent.mkdir(parents=True)
        copy_tree(bundle, app)
        launcher = deb / "usr/bin/getbible-live"
        launcher.parent.mkdir(parents=True)
        launcher.symlink_to("/opt/getbible-live/getbible_life")
        desktop = deb / "usr/share/applications/life.getbible.mobile.desktop"
        desktop.parent.mkdir(parents=True)
        shutil.copy2(require(repo / "packaging/linux/life.getbible.mobile.desktop"), desktop)
        icon = deb / "usr/share/icons/hicolor/512x512/apps/life.getbible.mobile.png"
        icon.parent.mkdir(parents=True)
        shutil.copy2(require(repo / "web/icons/Icon-512.png"), icon)
        control_dir = deb / "DEBIAN"
        control_dir.mkdir()

        # dpkg-shlibdeps needs a source control file, separate from the binary
        # package's control file. Resolve versions from the actual runner's ELF
        # dependencies instead of guessing distribution-specific GTK names.
        dependency_root = self.context.staging / "work/dependencies"
        (dependency_root / "debian").mkdir(parents=True)
        (dependency_root / "debian/control").write_text(
            "Source: getbible-live\nSection: education\nPriority: optional\n"
            f"Maintainer: {MAINTAINER}\n\nPackage: getbible-live\n"
            "Architecture: any\nDescription: Native Scripture reader\n", encoding="utf-8",
        )
        elves = [executable, *sorted((bundle / "lib").glob("*.so*"))]
        dependencies = run([
            tool("dpkg-shlibdeps"), "-O", "--ignore-missing-info",
            f"-l{bundle / 'lib'}", *[f"-e{path}" for path in elves if path.is_file()],
        ], cwd=dependency_root)
        matches = re.findall(r"^shlibs:Depends=(.+)$", dependencies, re.M)
        if len(matches) != 1:
            raise PackagingError("dpkg-shlibdeps did not return native runtime dependencies")
        installed_kib = sum(path.stat().st_size for path in deb.rglob("*") if path.is_file()) // 1024 + 1
        (control_dir / "control").write_text(
            f"Package: {APP}\nVersion: {metadata.release_version.replace('-', '~')}-{metadata.build_number}\n"
            f"Architecture: {'amd64' if self.arch == 'x64' else 'arm64'}\n"
            f"Maintainer: {MAINTAINER}\nSection: education\nPriority: optional\n"
            f"Depends: {matches[0]}\nInstalled-Size: {installed_kib}\n"
            "Homepage: https://getbible.net/\nDescription: getBible.live native Scripture reader\n"
            " Read and study Scripture with private notes and markings.\n", encoding="utf-8",
        )
        # SOURCE_DATE_EPOCH is interpreted by dpkg-deb and does not mutate the
        # caller's environment or the source Flutter bundle.
        output = self.output(".deb", "Debian package")
        result = subprocess.run(
            [str(tool("dpkg-deb")), "--root-owner-group", "--build", str(deb), str(output)],
            env={**os.environ, "SOURCE_DATE_EPOCH": str(metadata.source_date_epoch)},
            text=True, capture_output=True, check=False,
        )
        if result.returncode:
            raise PackagingError(f"dpkg-deb failed: {result.stdout}\n{result.stderr}")
        run([tool("dpkg-deb"), "--info", output])


class WindowsPackager(Packager):
    def sign(self, path: Path) -> None:
        hook = self.context.sign_hook
        if not hook:
            raise PackagingError("Distribution Windows packaging requires --sign-hook with the signing script")
        run([tool("pwsh"), "-NoProfile", "-File", require(hook), "-Paths", path])

    @staticmethod
    def verify_signature(path: Path) -> None:
        # Read the path through the process environment, never as executable
        # PowerShell source (workspaces may contain quotes and spaces).
        check = subprocess.run([
            str(tool("pwsh")), "-NoProfile", "-Command",
            "if ((Get-AuthenticodeSignature -LiteralPath $env:GETBIBLE_VERIFY_PATH).Status -ne 'Valid') { exit 1 }",
        ], env={**os.environ, "GETBIBLE_VERIFY_PATH": str(path)}, check=False, capture_output=True, text=True)
        if check.returncode:
            raise PackagingError(f"Authenticode verification failed: {path}\n{check.stderr}")

    def build(self) -> None:
        if self.arch != "x64":
            raise PackagingError("The Windows installer currently requires --arch x64")
        repo, metadata = self.context.repo, self.context.metadata
        bundle = self.bundle(self.context.input or repo / "build/windows/x64/runner/Release")
        executable = require(bundle / "getbible_life.exe")
        header = executable.read_bytes()
        if header[:2] != b"MZ" or len(header) < 64:
            raise PackagingError("Windows runner is not a PE executable")
        offset = struct.unpack_from("<I", header, 60)[0]
        if header[offset:offset + 6] != b"PE\0\0\x64\x86":
            raise PackagingError("Windows runner is not an x64 PE executable")
        require(bundle / "flutter_windows.dll")
        require(bundle / "data/app.so")
        require(bundle / "data/icudtl.dat")
        require(bundle / "data/flutter_assets", directory=True)
        program_files = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"))
        vswhere = require(program_files / "Microsoft Visual Studio/Installer/vswhere.exe")
        installation = Path(run([vswhere, "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"]))
        candidates = sorted(
            (installation / "VC/Redist/MSVC").glob("*/x64/Microsoft.VC*.CRT"),
            key=lambda path: tuple(int(n) for n in re.findall(r"\d+", path.parts[-3])),
        )
        if not candidates:
            raise PackagingError("Visual Studio's x64 Microsoft CRT redistribution directory is missing")
        for dll in sorted(candidates[-1].glob("*.dll")):
            shutil.copy2(dll, bundle / dll.name)
        for name in ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"):
            require(bundle / name)
        shutil.copy2(require(repo / "LICENSE"), bundle / "LICENSE")
        write_json(bundle / "release-metadata.json", asdict(metadata))
        if self.context.signing_mode == "distribution":
            self.signing = "Authenticode signed and timestamped"
            self.sign(bundle)
            self.verify_signature(executable)
        archive_zip(bundle, self.output("-portable.zip", "portable bundle including Microsoft CRT"), metadata.source_date_epoch)
        compiler = Path(shutil.which("ISCC.exe") or program_files / "Inno Setup 6/ISCC.exe")
        require(compiler)
        output = self.output("-setup.exe", "per-user Windows installer")
        run([
            compiler, "/Qp", f"/DAppVersion={metadata.version}",
            f"/DFileVersion={metadata.version_name}.{metadata.build_number}",
            f"/DOutputDir={self.context.staging}", f"/DOutputName={output.stem}",
            f"/DBundleDir={bundle}", f"/DSourceRoot={repo}",
            require(repo / "packaging/windows/getbible.iss"),
        ])
        if self.context.signing_mode == "distribution":
            self.sign(output)
            self.verify_signature(output)


class ApplePackager(Packager):
    @staticmethod
    def copy_app(source: Path, destination: Path) -> None:
        # Preserve signing tickets/resource forks as well as framework links.
        # Generic cross-platform file copying is insufficient for Apple bundles.
        validate_tree(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        run([tool("ditto"), source, destination])

    @staticmethod
    def verify_signature(path: Path, *, macos: bool) -> None:
        run([tool("codesign"), "--verify", "--deep", "--strict", path])
        details = subprocess.run(
            [str(tool("codesign")), "--display", "--verbose=4", str(path)],
            check=False, capture_output=True, text=True,
        )
        evidence = details.stdout + details.stderr
        authorities = ("Developer ID Application:",) if macos else ("Apple Distribution:", "iPhone Distribution:")
        if details.returncode or "Signature=adhoc" in evidence or not any(f"Authority={authority}" in evidence for authority in authorities):
            raise PackagingError(f"Application is not signed with the expected distribution identity: {path}")

    def read_app(self, source: Path, *, macos: bool) -> Path:
        require(source, directory=True)
        contents = source / "Contents" if macos else source
        with require(contents / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        expected_platform = "MacOSX" if macos else "iPhoneSimulator" if self.context.target == "ios-simulator" else "iPhoneOS"
        if expected_platform not in info.get("CFBundleSupportedPlatforms", []):
            raise PackagingError(f"Apple application was not built for {expected_platform}")
        metadata = self.context.metadata
        if info.get("CFBundleShortVersionString") != metadata.version_name or str(info.get("CFBundleVersion")) != str(metadata.build_number):
            raise PackagingError("Apple application version does not match release metadata; rebuild with the shared version")
        name = info.get("CFBundleExecutable")
        if not isinstance(name, str) or not name or Path(name).name != name:
            raise PackagingError("Apple application has an invalid executable name")
        executable = contents / ("MacOS" if macos else "") / name
        require(executable)
        arches = set(run([tool("lipo"), "-archs", executable]).split())
        if not arches or not arches <= {"arm64", "x86_64"}:
            raise PackagingError(f"Unsupported Apple architecture: {sorted(arches)}")
        self.arch = "universal" if len(arches) == 2 else {"arm64": "arm64", "x86_64": "x64"}[arches.pop()]
        destination = self.context.staging / "work" / source.name
        self.copy_app(source, destination)
        return destination

    def zip_app(self, bundle: Path, role: str) -> None:
        # Apple's ditto retains framework symlinks, resource forks and executable
        # modes. This is intentionally host-native, not a generic folder ZIP.
        run([tool("ditto"), "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, self.output(".app.zip", role)])


class MacOSPackager(ApplePackager):
    signing = "unsigned distribution; local ad-hoc build signature may be present"

    def build(self) -> None:
        bundle = self.read_app(self.context.input or self.context.repo / "build/macos/Build/Products/Release/getBible.live.app", macos=True)
        if self.context.signing_mode == "distribution":
            self.verify_signature(bundle, macos=True)
            run([tool("xcrun"), "stapler", "validate", bundle])
            self.signing = "Developer ID signed, notarized and stapled"
        self.zip_app(bundle, "macOS application bundle")
        image_root = self.context.staging / "work/dmg"
        image_root.mkdir()
        self.copy_app(bundle, image_root / bundle.name)
        (image_root / "Applications").symlink_to("/Applications", target_is_directory=True)
        shutil.copy2(require(self.context.repo / "LICENSE"), image_root / "LICENSE")
        write_json(image_root / "release-metadata.json", asdict(self.context.metadata))
        image = self.output(".dmg", "macOS drag-to-Applications disk image")
        run([tool("hdiutil"), "create", "-volname", "getBible.live", "-srcfolder", image_root, "-format", "UDZO", "-ov", image])
        if self.context.signing_mode == "distribution":
            if not self.context.sign_hook:
                raise PackagingError("Distribution macOS packaging requires --sign-hook to sign/notarize/staple the DMG")
            run([tool("bash"), require(self.context.sign_hook), image])
            self.verify_signature(image, macos=True)
            run([tool("xcrun"), "stapler", "validate", image])


class IOSPackager(ApplePackager):
    def build(self) -> None:
        simulator = self.context.target == "ios-simulator"
        self.signing = "simulator build" if simulator else "unsigned; requires Apple provisioning and distribution signing"
        self.installability = "Xcode simulator only" if simulator else "device build validation only; not an installable IPA"
        relative = "build/ios/iphonesimulator/Runner.app" if simulator else "build/ios/iphoneos/Runner.app"
        bundle = self.read_app(self.context.input or self.context.repo / relative, macos=False)
        self.zip_app(bundle, "iOS simulator application" if simulator else "unsigned iOS device application")


class AndroidPackager(Packager):
    signing = "debug APK: development key; release APK/AAB: unsigned"
    installability = "debug APK installs on Android phones/tablets; release packages require signing"

    def build(self) -> None:
        self.arch = "multiarch"
        signed = self.context.target == "android-signed"
        if signed:
            self.signing = "release APK/AAB signed with the configured Android upload key"
            self.installability = "signed APK installs on Android; signed AAB is a Play Console upload"
        source = self.context.input or self.context.repo / "build/app/outputs"
        files = [
            ("flutter-apk/app-debug.apk", "-debug.apk", "installable development APK", "AndroidManifest.xml"),
            ("flutter-apk/app-release.apk", "-unsigned-release.apk", "unsigned release APK", "AndroidManifest.xml"),
            ("bundle/release/app-release.aab", "-unsigned-release.aab", "unsigned Play bundle", "base/manifest/AndroidManifest.xml"),
        ]
        if signed:
            files = [
                ("flutter-apk/app-release.apk", "-release.apk", "signed release APK", "AndroidManifest.xml"),
                ("bundle/release/app-release.aab", "-release.aab", "signed Play bundle", "base/manifest/AndroidManifest.xml"),
            ]
        for relative, suffix, role, manifest in files:
            path = require(source / relative)
            with zipfile.ZipFile(path) as archive:
                if manifest not in archive.namelist() or archive.testzip() is not None:
                    raise PackagingError(f"Invalid Android package: {path}")
                if signed and path.suffix == ".aab":
                    certificates = [name for name in archive.namelist() if re.fullmatch(r"META-INF/[^/]+\.(RSA|DSA|EC)", name)]
                    if not certificates:
                        raise PackagingError("The Android App Bundle has no signing certificate")
            if signed:
                if path.suffix == ".apk":
                    signer = require(self.context.apksigner) if self.context.apksigner else tool("apksigner")
                    run([signer, "verify", "--verbose", "--print-certs", path])
                else:
                    verification = run([tool("jarsigner"), "-verify", "-verbose", "-certs", path])
                    # Android upload certificates are normally self-signed, so
                    # jarsigner -strict would reject a valid upload key. Require
                    # successful cryptographic verification instead.
                    if "jar verified." not in verification:
                        raise PackagingError("jarsigner did not verify the signed Android App Bundle")
            shutil.copy2(path, self.output(suffix, role))


class SignedIOSPackager(ApplePackager):
    signing = "Apple distribution signed with embedded provisioning profile"
    installability = "distribution IPA; installation channel follows the embedded provisioning profile"

    def build(self) -> None:
        source = self.context.input
        if not source:
            candidates = list((self.context.repo / "build/ios/ipa").glob("*.ipa"))
            if len(candidates) != 1:
                raise PackagingError("Expected exactly one exported IPA; pass --input to select it")
            source = candidates[0]
        require(source)
        with zipfile.ZipFile(source) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)) or archive.testzip() is not None:
                raise PackagingError("Invalid or duplicate entries in exported IPA")
            for name in names:
                if name.startswith("/") or ".." in Path(name).parts or "\\" in name:
                    raise PackagingError("Unsafe path in exported IPA")
        unpacked = self.context.staging / "work/ipa"
        unpacked.mkdir(parents=True)
        run([tool("ditto"), "-x", "-k", source, unpacked])
        apps = list((unpacked / "Payload").glob("*.app"))
        if len(apps) != 1:
            raise PackagingError("Exported IPA must contain exactly one application")
        app = self.read_app(apps[0], macos=False)
        self.verify_signature(app, macos=False)
        profile = plistlib.loads(run([tool("security"), "cms", "-D", "-i", require(app / "embedded.mobileprovision")]).encode("utf-8"))
        expiry = profile.get("ExpirationDate")
        if not isinstance(expiry, datetime) or expiry.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
            raise PackagingError("The IPA provisioning profile is expired")
        if profile.get("Entitlements", {}).get("get-task-allow", False):
            raise PackagingError("The IPA contains development provisioning, not distribution provisioning")
        shutil.copy2(source, self.output(".ipa", "signed iOS/iPadOS distribution archive"))


class WebPackager(Packager):
    signing = "not applicable"
    installability = "serve extracted files over HTTPS (HTTP for localhost testing)"

    def build(self) -> None:
        self.arch = "browser"
        base_href = self.context.base_href
        if not re.fullmatch(r"/(?:[A-Za-z0-9._~-]+/)*", base_href):
            raise PackagingError("--base-href must be an absolute URL path with leading/trailing slash")
        bundle = self.bundle(self.context.input or self.context.repo / "build/web")
        index = require(bundle / "index.html").read_text(encoding="utf-8")
        if not re.search(r'<base\s+href=[\"\']' + re.escape(base_href) + r'[\"\']\s*/?>', index):
            raise PackagingError(f"Web index.html does not use --base-href {base_href}; rebuild Flutter with that base path")
        require(bundle / "flutter_bootstrap.js")
        require(bundle / "main.dart.js")
        require(bundle / "assets", directory=True)
        require(bundle / "sqlite3.wasm")
        require(bundle / "drift_worker.dart.js")
        require(bundle / "offline_bible_worker.dart.js")
        write_json(bundle / "release-metadata.json", {**asdict(self.context.metadata), "base_href": base_href})
        shutil.copy2(require(self.context.repo / "LICENSE"), bundle / "LICENSE")
        archive_zip(bundle, self.output(".zip", "static web application"), self.context.metadata.source_date_epoch, parent=False)

    def manifest(self) -> dict:
        return {**super().manifest(), "base_href": self.context.base_href}


PACKAGERS = {
    "linux": LinuxPackager, "windows": WindowsPackager, "macos": MacOSPackager,
    "ios-device": IOSPackager, "ios-simulator": IOSPackager,
    "android": AndroidPackager, "android-signed": AndroidPackager,
    "ios-signed": SignedIOSPackager, "web": WebPackager,
}


def package(args: argparse.Namespace) -> None:
    repo = args.repo.resolve()
    if getattr(args, "signing_mode", "unsigned") == "distribution" and args.target not in ("windows", "macos", "android-signed", "ios-signed"):
        raise PackagingError("Distribution signing mode requires windows, macos, android-signed or ios-signed")
    metadata = ReleaseMetadata.load(args.metadata, repo)
    output = args.output.resolve()
    source = args.input.resolve() if args.input else None
    if source and (output == source or output.is_relative_to(source)):
        raise PackagingError("Output directory must be outside the input bundle")
    output.mkdir(parents=True, exist_ok=True)
    published: list[Path] = []
    with tempfile.TemporaryDirectory(prefix=".package-", dir=output.parent) as temporary:
        staging = Path(temporary)
        context = PackageContext(
            repo, metadata, staging, args.target, args.arch, source, args.base_href,
            getattr(args, "signing_mode", "unsigned"), getattr(args, "sign_hook", None),
            getattr(args, "apksigner", None),
        )
        packager = PACKAGERS[args.target](context)
        packager.build()
        manifest = staging / f"{packager.prefix}-manifest.json"
        write_json(manifest, packager.manifest())
        files = [path for path, _ in packager.artifacts] + [manifest]
        checksums = staging / f"{packager.prefix}-SHA256SUMS"
        checksums.write_text("".join(f"{sha256(path)}  {path.name}\n" for path in files), encoding="utf-8")
        files.append(checksums)
        for path in files:
            if (output / path.name).exists():
                raise PackagingError(f"Refusing to overwrite existing release artifact: {output / path.name}")
        try:
            for path in files:
                destination = output / path.name
                path.rename(destination)
                published.append(destination)
        except OSError:
            for destination in published:
                destination.unlink()
            raise
    for path in published:
        print(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    metadata_parser = commands.add_parser("metadata", help="Create shared build/version metadata")
    metadata_parser.add_argument("--repo", type=Path, default=ROOT)
    metadata_parser.add_argument("--build-number", type=int)
    metadata_parser.add_argument("--output", type=Path, required=True)
    metadata_parser.add_argument("--github-output", type=Path)
    package_parser = commands.add_parser("package", help="Package an existing production build")
    package_parser.add_argument("--repo", type=Path, default=ROOT)
    package_parser.add_argument("--target", choices=PACKAGERS, required=True)
    package_parser.add_argument("--metadata", type=Path, required=True)
    package_parser.add_argument("--output", type=Path, default=Path("dist"))
    package_parser.add_argument("--input", type=Path)
    package_parser.add_argument("--arch", choices=("x64", "arm64"), default="x64")
    package_parser.add_argument("--base-href", default="/flutter/")
    package_parser.add_argument("--signing-mode", choices=("unsigned", "distribution"), default="unsigned")
    package_parser.add_argument("--sign-hook", type=Path, help="Platform signing script, invoked only for explicit distribution packaging")
    package_parser.add_argument("--apksigner", type=Path, help="Android SDK apksigner path for android-signed verification")
    args = parser.parse_args()
    try:
        if args.command == "metadata":
            metadata = ReleaseMetadata.create(args.repo.resolve(), args.build_number)
            write_json(args.output, asdict(metadata))
            if args.github_output:
                with args.github_output.open("a", encoding="utf-8") as target:
                    for key in ("release_version", "version_name", "build_number", "channel", "version", "artifact_version", "git_sha", "source_date_epoch"):
                        target.write(f"{key}={getattr(metadata, key)}\n")
            print(json.dumps(asdict(metadata), sort_keys=True))
        else:
            package(args)
    except (PackagingError, OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"Packaging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
