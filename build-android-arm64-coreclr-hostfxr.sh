#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly repo_root="$script_dir"
readonly target_os="android"
readonly target_arch="arm64"
readonly runtime_flavor="CoreCLR"
readonly runtime_pack_id="Microsoft.NETCore.App.Runtime.android-arm64"
readonly versions_props_path="$repo_root/eng/Versions.props"
readonly build_script_path="$repo_root/build.sh"

config="Release"
extra_args=()

stabilize_package_version="${ANDROID_STABILIZE_PACKAGE_VERSION:-true}"
api_compat_validate_assemblies="${ANDROID_APICOMPAT_VALIDATE_ASSEMBLIES:-false}"
enable_package_validation="${ANDROID_ENABLE_PACKAGE_VALIDATION:-false}"
layout_root="${ANDROID_LAYOUT_ROOT:-$repo_root/artifacts/layout/android-arm64-dotnet}"
runtime_version=""
runtime_pack_package_path=""
host_dir=""
fxr_dir=""
shared_dir=""
shared_framework_tfm=""
layout_archive_path=""

usage() {
  cat <<'EOF'
Usage:
  ./build-android-arm64-coreclr-hostfxr.sh [Debug|Release|Checked] [additional build.sh args...]

Examples:
  ./build-android-arm64-coreclr-hostfxr.sh
  ./build-android-arm64-coreclr-hostfxr.sh Debug
  ./build-android-arm64-coreclr-hostfxr.sh Release -keepnativesymbols true

Environment overrides:
  ANDROID_SDK_ROOT                Required Android SDK path
  ANDROID_NDK_ROOT                Optional Android NDK path; inferred from ANDROID_SDK_ROOT/ndk if unset
  ANDROID_LAYOUT_ROOT             Output directory for dotnet-style layout
  ANDROID_STABILIZE_PACKAGE_VERSION
  ANDROID_APICOMPAT_VALIDATE_ASSEMBLIES
  ANDROID_ENABLE_PACKAGE_VALIDATION
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

log_step() {
  echo
  echo "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH."
}

require_file() {
  [[ -f "$1" ]] || die "Missing file: $1"
}

require_dir() {
  [[ -d "$1" ]] || die "Missing directory: $1"
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      Debug|Release|Checked)
        config="$1"
        shift
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
    esac
  fi

  extra_args=("$@")
}

infer_android_ndk_root() {
  local sdk_ndk_dir inferred_ndk_version

  sdk_ndk_dir="$ANDROID_SDK_ROOT/ndk"
  [[ -d "$sdk_ndk_dir" ]] || return 1

  inferred_ndk_version="$(
    find "$sdk_ndk_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | sort -V \
      | tail -n 1
  )"
  [[ -n "$inferred_ndk_version" ]] || return 1

  printf '%s\n' "$sdk_ndk_dir/$inferred_ndk_version"
}

resolve_android_toolchain() {
  [[ -n "${ANDROID_SDK_ROOT:-}" ]] || die "ANDROID_SDK_ROOT is not set. Export it before running this script."

  if [[ -z "${ANDROID_NDK_ROOT:-}" ]]; then
    ANDROID_NDK_ROOT="$(infer_android_ndk_root || true)"
    export ANDROID_NDK_ROOT
  fi

  [[ -n "${ANDROID_NDK_ROOT:-}" ]] || die "ANDROID_NDK_ROOT is not set and could not be inferred from ANDROID_SDK_ROOT/ndk."
}

validate_environment() {
  local java_version_output

  require_command java
  require_command rg
  require_command jq
  require_command tar
  require_command xz
  require_command unzip
  require_dir "$ANDROID_SDK_ROOT"
  require_dir "$ANDROID_NDK_ROOT"
  [[ -x "$build_script_path" ]] || die "build.sh not found or not executable at: $build_script_path"
  require_file "$versions_props_path"

  java_version_output="$(java -version 2>&1 | head -n 1 || true)"
  if [[ "$java_version_output" != *'"23.'* ]]; then
    warn "Android CoreCLR docs recommend OpenJDK 23. Current java reports: $java_version_output"
  fi
}

print_environment_summary() {
  echo "Using ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT"
  echo "Using ANDROID_NDK_ROOT=$ANDROID_NDK_ROOT"
  echo "Using ANDROID_STABILIZE_PACKAGE_VERSION=$stabilize_package_version"
  echo "Using ANDROID_APICOMPAT_VALIDATE_ASSEMBLIES=$api_compat_validate_assemblies"
  echo "Using ANDROID_ENABLE_PACKAGE_VALIDATION=$enable_package_validation"
}

build_step() {
  local subset

  subset="$1"
  shift

  "$build_script_path" \
    "$subset" \
    -os "$target_os" \
    -arch "$target_arch" \
    -c "$config" \
    /p:StabilizePackageVersion="$stabilize_package_version" \
    /p:ApiCompatValidateAssemblies="$api_compat_validate_assemblies" \
    /p:EnablePackageValidation="$enable_package_validation" \
    "$@" \
    "${extra_args[@]}"
}

build_coreclr_runtime() {
  log_step "Building Android ARM64 CoreCLR in $config"
  build_step "clr.runtime+clr.alljits+clr.corelib+clr.nativecorelib+clr.tools+clr.packages+libs"
}

build_host_native() {
  log_step "Building Android ARM64 native host components in $config"
  build_step "host.native" "/p:RuntimeFlavor=$runtime_flavor"
}

build_runtime_pack() {
  log_step "Building Android ARM64 runtime pack in $config"
  build_step "packs.product" "/p:RuntimeFlavor=$runtime_flavor"
}

read_product_version() {
  local major_version minor_version patch_version

  major_version="$(rg -o -P '(?<=<MajorVersion>)[0-9]+' "$versions_props_path" | head -n 1)"
  minor_version="$(rg -o -P '(?<=<MinorVersion>)[0-9]+' "$versions_props_path" | head -n 1)"
  patch_version="$(rg -o -P '(?<=<PatchVersion>)[0-9]+' "$versions_props_path" | head -n 1)"
  [[ -n "$major_version" && -n "$minor_version" && -n "$patch_version" ]] || die "Unable to determine product version from $versions_props_path."

  printf '%s.%s.%s\n' "$major_version" "$minor_version" "$patch_version"
}

find_runtime_pack_package() {
  local shipping_dir

  shipping_dir="$repo_root/artifacts/packages/$config/Shipping"
  [[ -d "$shipping_dir" ]] || return 1

  find "$shipping_dir" -maxdepth 1 -type f \
    -name "${runtime_pack_id}.*.nupkg" \
    ! -name '*.symbols.nupkg' \
    | sort -V \
    | tail -n 1
}

extract_runtime_version_from_package_path() {
  local package_name version

  package_name="$(basename "$1")"
  version="${package_name#${runtime_pack_id}.}"
  version="${version%.nupkg}"
  [[ -n "$version" ]] || return 1

  printf '%s\n' "$version"
}

resolve_runtime_pack_metadata() {
  local product_version

  product_version="$(read_product_version)"
  runtime_pack_package_path="$(find_runtime_pack_package || true)"

  if [[ "$stabilize_package_version" == "true" ]]; then
    runtime_version="$product_version"
  elif [[ -n "$runtime_pack_package_path" ]]; then
    runtime_version="$(extract_runtime_version_from_package_path "$runtime_pack_package_path")"
  else
    runtime_version="${product_version}-dev"
    warn "Falling back to inferred runtime version $runtime_version because the runtime pack package was not found."
  fi

  if [[ -z "$runtime_pack_package_path" ]]; then
    runtime_pack_package_path="$repo_root/artifacts/packages/$config/Shipping/${runtime_pack_id}.${runtime_version}.nupkg"
  fi

  shared_framework_tfm="net${runtime_version%%.*}.$(printf '%s' "$runtime_version" | cut -d. -f2)"
  host_dir="$repo_root/artifacts/bin/${target_os}-${target_arch}.${config}/corehost"
  fxr_dir="$layout_root/host/fxr/$runtime_version"
  shared_dir="$layout_root/shared/Microsoft.NETCore.App/$runtime_version"
  layout_archive_path="${layout_root}.tar.xz"
}

extract_runtime_pack_file() {
  local package_path package_entry output_path

  package_path="$1"
  package_entry="$2"
  output_path="$3"

  mkdir -p "$(dirname "$output_path")"
  unzip -p "$package_path" "$package_entry" > "$output_path"
}

extract_runtime_pack_dir_flat() {
  local package_path package_prefix output_dir package_entry output_path entry_name
  local excluded_names
  local should_skip

  package_path="$1"
  package_prefix="$2"
  output_dir="$3"
  shift 3
  excluded_names=("$@")

  mkdir -p "$output_dir"

  while IFS= read -r package_entry; do
    [[ -n "$package_entry" ]] || continue
    entry_name="$(basename "$package_entry")"
    should_skip="false"

    for excluded_name in "${excluded_names[@]}"; do
      if [[ "$entry_name" == "$excluded_name" ]]; then
        should_skip="true"
        break
      fi
    done

    [[ "$should_skip" == "true" ]] && continue

    output_path="$output_dir/$entry_name"
    unzip -p "$package_path" "$package_entry" > "$output_path"
  done < <(unzip -Z1 "$package_path" | rg "^${package_prefix}/[^/]+$")
}

validate_layout_inputs() {
  require_file "$host_dir/dotnet"
  require_file "$host_dir/libhostfxr.so"
  require_file "$host_dir/libhostpolicy.so"
  require_file "$runtime_pack_package_path"
}

trim_shared_framework_static_archives() {
  local deps_path temp_deps_path

  deps_path="$shared_dir/Microsoft.NETCore.App.deps.json"
  require_file "$deps_path"

  find "$shared_dir" -maxdepth 1 -type f -name '*.a' -delete

  temp_deps_path="$(mktemp)"
  jq '
    .targets |= with_entries(
      .value |= with_entries(
        if (.value.native? | type) == "object" then
          .value.native |= with_entries(select(.key | endswith(".a") | not))
        else
          .
        end
      )
    )
  ' "$deps_path" > "$temp_deps_path"
  mv "$temp_deps_path" "$deps_path"
}

create_dotnet_layout() {
  local runtime_pack_lib_prefix runtime_pack_native_prefix
  local runtime_pack_deps_entry runtime_pack_runtimeconfig_entry

  runtime_pack_lib_prefix="runtimes/${target_os}-${target_arch}/lib/$shared_framework_tfm"
  runtime_pack_native_prefix="runtimes/${target_os}-${target_arch}/native"
  runtime_pack_deps_entry="$runtime_pack_lib_prefix/Microsoft.NETCore.App.deps.json"
  runtime_pack_runtimeconfig_entry="$runtime_pack_lib_prefix/Microsoft.NETCore.App.runtimeconfig.json"

  validate_layout_inputs

  log_step "Creating dotnet-style layout"

  rm -rf "$layout_root"
  mkdir -p "$fxr_dir" "$shared_dir"

  install -m 755 "$host_dir/dotnet" "$layout_root/dotnet"
  install -m 755 "$host_dir/libhostfxr.so" "$fxr_dir/libhostfxr.so"
  install -m 755 "$host_dir/libhostpolicy.so" "$shared_dir/libhostpolicy.so"

  extract_runtime_pack_dir_flat \
    "$runtime_pack_package_path" \
    "$runtime_pack_lib_prefix" \
    "$shared_dir" \
    "Microsoft.NETCore.App.deps.json" \
    "Microsoft.NETCore.App.runtimeconfig.json"
  extract_runtime_pack_dir_flat "$runtime_pack_package_path" "$runtime_pack_native_prefix" "$shared_dir"

  extract_runtime_pack_file "$runtime_pack_package_path" "$runtime_pack_deps_entry" "$shared_dir/Microsoft.NETCore.App.deps.json"
  extract_runtime_pack_file "$runtime_pack_package_path" "$runtime_pack_runtimeconfig_entry" "$shared_dir/Microsoft.NETCore.App.runtimeconfig.json"
  trim_shared_framework_static_archives

  echo "Layout root:       $layout_root"
  echo "Host entrypoint:   $layout_root/dotnet"
  echo "Hostfxr location:  $fxr_dir/libhostfxr.so"
  echo "Shared FX dir:     $shared_dir"
  echo "Deps manifest:     $shared_dir/Microsoft.NETCore.App.deps.json"
  echo "Runtime config:    $shared_dir/Microsoft.NETCore.App.runtimeconfig.json"
}

create_layout_archive() {
  local archive_entries=()

  log_step "Creating layout archive"

  require_dir "$layout_root"

  rm -f "$layout_archive_path"
  (
    cd "$layout_root"
    shopt -s nullglob
    archive_entries=( * )
    [[ ${#archive_entries[@]} -gt 0 ]] || die "Layout directory is empty: $layout_root"

    tar \
      --sort=name \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      -cJf "$layout_archive_path" \
      "${archive_entries[@]}"
  )

  echo "Layout archive:    $layout_archive_path"
}

print_completion_summary() {
  echo
  echo "Build completed."
  echo "CoreCLR artifacts: $repo_root/artifacts/bin/coreclr/${target_os}.${target_arch}.${config}/"
  echo "Host artifacts:    $host_dir/"
  echo "Runtime pack:      $runtime_pack_package_path"
}

main() {
  parse_args "$@"
  resolve_android_toolchain
  validate_environment
  print_environment_summary

  cd "$repo_root"

  build_coreclr_runtime
  build_host_native
  build_runtime_pack

  resolve_runtime_pack_metadata
  create_dotnet_layout
  create_layout_archive
  print_completion_summary
}

main "$@"
