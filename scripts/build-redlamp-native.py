import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Vendor/Redlamp"
BUILD = ROOT / ".build/redlamp-native"
FRAMEWORKS = BUILD / "Frameworks"
SDK = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
TARGET = "arm64-apple-macosx26.3"
os.environ.setdefault("CLANG_MODULE_CACHE_PATH", "/private/tmp/photolab-module-cache")


def run(arguments):
    subprocess.run([str(item) for item in arguments], check=True)


def digest(paths):
    checksum = hashlib.sha256(Path(__file__).read_bytes())
    checksum.update(subprocess.check_output(["xcrun", "swiftc", "--version"]))
    for path in sorted(paths):
        checksum.update(str(path.relative_to(ROOT)).encode())
        checksum.update(path.read_bytes())
    return checksum.hexdigest()


def libraw():
    config = json.loads((SOURCE / "config/vendored-libs.json").read_text())["LibRaw"]
    archive = SOURCE / "vendor/LibRaw.tar.gz"
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != config["sha256"]:
        raise RuntimeError("Missing or invalid Vendor/Redlamp/vendor/LibRaw.tar.gz; see Vendor/Redlamp/source.json")
    output = BUILD / "libraw.a"
    headers = BUILD / "Headers/LibRaw"
    headers.mkdir(parents=True, exist_ok=True)
    if output.exists():
        return output, headers.parent
    extracted = BUILD / "LibRaw"
    extracted.mkdir(exist_ok=True)
    with tarfile.open(archive) as package:
        package.extractall(extracted, filter="data")
    sources = next(extracted.iterdir())
    for path in (sources / "libraw").glob("*.h"):
        shutil.copy2(path, headers / path.name)
    shutil.copy2(SOURCE / "vendor/shims/redlamp_libraw.h", headers)
    (headers / "redlamp_libraw_pin.h").write_text(f'static inline const char *rl_libraw_pin(void) {{ return "{config["version"]}"; }}\nstatic inline const char *rl_libraw_source(void) {{ return "pdcgomes/redlamp-libraw"; }}\n')
    (headers / "module.modulemap").write_text('module LibRaw { header "libraw.h" header "redlamp_libraw.h" header "redlamp_libraw_pin.h" link "c++" link "z" export * }\n')
    listing = re.search(r"^LIB_OBJECTS=(.*?)(?=\n[^\s])", (sources / "Makefile.dist").read_text(), re.M | re.S)[1]
    names = re.findall(r"object/([\w]+)\.o", listing)
    objects = BUILD / "libraw-objects"
    objects.mkdir(exist_ok=True)
    def compile_one(name):
        source = next((sources / "src").rglob(name + ".cpp"))
        run(["xcrun", "clang++", "-c", source, "-o", objects / (name + ".o"), "-target", TARGET,
             "-isysroot", SDK, "-I", sources, "-std=c++17", "-O3", "-w", "-fPIC", "-fvisibility=hidden",
             "-fvisibility-inlines-hidden", "-DUSE_ZLIB", "-DLIBRAW_NODLL"])
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(compile_one, names))
    run(["xcrun", "libtool", "-static", "-o", output, *sorted(objects.glob("*.o"))])
    return output, headers.parent


def framework(name, sources, dependencies, resources=None, extra=()):
    folder = FRAMEWORKS / (name + ".framework")
    binary = folder / name
    inputs = list(sources.rglob("*.swift"))
    files = [path for path in sources.rglob("*") if path.is_file()]
    if resources and resources.exists():
        files += [path for path in resources.rglob("*") if path.is_file()]
    files += [SOURCE / "source.json", SOURCE / "vendor/default.metallib", SOURCE / "config/vendored-libs.json"]
    dependency_versions = [((BUILD / (dependency + ".stamp")).read_text()) for dependency in dependencies]
    version = hashlib.sha256((digest(files) + SDK + TARGET + os.environ.get("PHOTOLAB_COMPILE_METAL", "0") + "".join(dependency_versions)).encode()).hexdigest()
    stamp = BUILD / (name + ".stamp")
    if binary.exists() and stamp.exists() and stamp.read_text() == version:
        return
    print("Building", name, flush=True)
    modules = folder / "Modules" / (name + ".swiftmodule")
    modules.mkdir(parents=True, exist_ok=True)
    resource_folder = folder / "Resources"
    resource_folder.mkdir(exist_ok=True)
    if resources and resources.exists():
        shutil.copytree(resources, resource_folder, dirs_exist_ok=True)
    (resource_folder / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "local.photolab.native." + name,
        "CFBundleExecutable": name, "CFBundlePackageType": "FMWK", "CFBundleName": name}))
    run(["xcrun", "swiftc", "-sdk", SDK, "-target", TARGET, "-swift-version", "6", "-O", "-whole-module-optimization",
         "-parse-as-library", "-emit-library", "-emit-module", "-module-name", name,
         "-emit-module-path", modules / "arm64-apple-macos.swiftmodule", "-F", FRAMEWORKS, "-I", BUILD / "Headers",
         *[argument for dependency in dependencies for argument in ["-framework", dependency]], *extra,
         "-Xlinker", "-install_name", "-Xlinker", f"@rpath/{name}.framework/{name}",
         "-Xlinker", "-rpath", "-Xlinker", "@loader_path/..", *sorted(inputs), "-o", binary])
    metal = sorted(sources.rglob("*.metal"))
    if metal and os.environ.get("PHOTOLAB_COMPILE_METAL") != "1":
        library = SOURCE / "vendor/default.metallib"
        metadata = json.loads((SOURCE / "source.json").read_text())
        if hashlib.sha256(library.read_bytes()).hexdigest() != metadata["metallib_sha256"]:
            raise RuntimeError("Metal library checksum mismatch")
        shutil.copy2(library, resource_folder / "default.metallib")
    elif metal:
        intermediates = BUILD / "metal"
        intermediates.mkdir(exist_ok=True)
        def compile_metal(path):
            output = intermediates / (path.stem + ".air")
            run(["xcrun", "-sdk", "macosx", "metal", "-c", path, "-I", path.parent,
                 "-mmacosx-version-min=26.3", "-o", output])
            return output
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            compiled = list(pool.map(compile_metal, metal))
        run(["xcrun", "metallib", *compiled, "-o", resource_folder / "default.metallib"])
    run(["codesign", "--force", "--sign", "-", folder])
    stamp.write_text(version)


BUILD.mkdir(parents=True, exist_ok=True)
FRAMEWORKS.mkdir(exist_ok=True)
raw, headers = libraw()
dependencies = {
    "RedlampEngineAPI": [], "RedlampKernels": [], "RedlampColor": ["RedlampEngineAPI"],
    "RedlampServices": ["RedlampEngineAPI"], "RedlampMasking": ["RedlampEngineAPI", "RedlampColor"],
    "RedlampEngine": ["RedlampEngineAPI", "RedlampKernels", "RedlampColor", "RedlampServices", "RedlampMasking"],
}
for name, upstream in dependencies.items():
    folder = SOURCE / "packages" / name
    framework(name, folder / "Sources", upstream, folder / "Resources",
              ["-I", headers, raw, "-lc++", "-lz"] if name == "RedlampServices" else [])
framework("PhotoLabRedlamp", ROOT / "Native/PhotoLabRedlamp", ["RedlampEngine", "RedlampEngineAPI", "RedlampServices"])
print(FRAMEWORKS, flush=True)
