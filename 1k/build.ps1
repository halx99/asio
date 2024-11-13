# //////////////////////////////////////////////////////////////////////////////////////////
# // A multi-platform support c++11 library with focus on asynchronous socket I/O for any
# // client application.
# //////////////////////////////////////////////////////////////////////////////////////////
#
# The MIT License (MIT)
#
# Copyright (c) 2012-2024 HALX99
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#
# The 1k/build.ps1, the core script of project 1kiss(1k)
# options
#  -p: build target platform: win32,winrt(winuwp),linux,android,osx(mac),ios,tvos,watchos,wasm
#      for android: will search ndk in sdk_root which is specified by env:ANDROID_HOME first,
#      if not found, by default will install ndk-r16b or can be specified by option: -cc 'ndk-r23c'
#  -a: build arch: x86,x64,armv7,arm64
#  -d: the build workspace, i.e project root which contains root CMakeLists.txt, empty use script run working directory aka cwd
#  -cc: The C/C++ compiler toolchain: clang, msvc, gcc(mingw) or empty use default installed on current OS
#       msvc: msvc-120, msvc-141
#       ndk: ndk-r16b, ndk-r16b+
#  -xt: cross build tool, default: cmake, for android can be gradlew, can be path of cross build tool program
#  -xc: cross build tool configure options: i.e.  -xc '-Dbuild'
#  -xb: cross build tool build options: i.e. -xb '--config','Release'
#  -prefix: the install location for missing tools in system, default is "$HOME/.1kiss"
#  -sdk: specific windows sdk version, i.e. -sdk '10.0.19041.0', leave empty, cmake will auto choose latest avaiable
#  -setupOnly: this param present, only execute step: setup
#  -configOnly: if this param present, will skip build step
# support matrix
#   | OS       |   Build targets      |  C/C++ compiler toolchain | Cross Build tool |
#   +----------+----------------------+---------------------------+------------------|
#   | Windows  |  win32,winrt        | msvc,clang,gcc(mingw)     | cmake            |
#   | Linux    | linux,android        | gcc,ndk                   | cmake,gradle     |
#   | macOS    | osx,ios,tvos,watchos | xcode                     | cmake            |
# android gradle, there a two props:
#   - -P__1K_CMAKE_VERSION
#   - -P__1k_ARCHS
# startsWith('__1K') indicate 1k gradle props
# startsWith('_1K') indicate it's a cmake config option
#
param(
    [switch]$configOnly,
    [switch]$setupOnly,
    [switch]$forceConfig,
    [switch]$ndkOnly
)

$myRoot = $PSScriptRoot

# ----------------- utils functions -----------------

$HOST_WIN = 0 # targets: win,uwp,android
$HOST_LINUX = 1 # targets: linux,android
$HOST_MAC = 2 # targets: android,ios,osx(macos),tvos,watchos

# 0: windows, 1: linux, 2: macos
$Global:IsWin = $IsWindows -or ("$env:OS" -eq 'Windows_NT')
if ($Global:IsWin) {
    $HOST_OS = $HOST_WIN
    $ENV_PATH_SEP = ';'
}
else {
    $ENV_PATH_SEP = ':'
    if ($IsLinux) {
        $HOST_OS = $HOST_LINUX
    }
    elseif ($IsMacOS) {
        $HOST_OS = $HOST_MAC
    }
    else {
        throw "Unsupported host OS to run 1k/build.ps1"
    }
}

$exeSuffix = if ($HOST_OS -eq 0) { '.exe' } else { '' }

$Script:cmake_generator = $null

# import VersionEx
. (Join-Path $PSScriptRoot 'extensions.ps1')

class build1k {
    [void] println($msg) {
        Write-Host "1kiss: $msg"
    }

    [void] print($msg) {
        Write-Host "1kiss: $msg" -NoNewline
    }

    [System.Boolean] isfile([string]$path) {
        return Test-Path $path -PathType Leaf
    }

    [System.Boolean] isdir([string]$path) {
        return Test-Path $path -PathType Container
    }

    [void] mkdirs([string]$path) {
        if (!(Test-Path $path -PathType Container)) {
            New-Item $path -ItemType Directory 1>$null
        }
    }

    [void] rmdirs([string]$path) {
        if ($this.isdir($path)) {
            $this.println("Deleting $path ...")
            Remove-Item $path -Recurse -Force
        }
    }

    [void] del([string]$path) {
        if ($this.isfile($path)) {
            $this.println("Deleting $path ...")
            Remove-Item $path -Force
        }
    }

    [void] mv([string]$path, [string]$dest) {
        if ($this.isdir($path) -and !$this.isdir($dest)) {
            Move-Item $path $dest
        }
    }

    [void] pause($msg) {
        $executed_from_explorer = $false
        do {
            if (!$Global:IsWin) { break }
            $myProcess = [System.Diagnostics.Process]::GetCurrentProcess()
            if ($myProcess.ProcessName.EndsWith('_ise')) { break }
            $parentProcess = $myProcess.Parent
            if (!$parentProcess) {
                $myPID = $myProcess.Id
                $instance = Get-WmiObject Win32_Process -Filter "ProcessId = $myPID"
                $parentProcess = Get-Process -Id $instance.ParentProcessID -ErrorAction SilentlyContinue
                if (!$parentProcess) { break }
            }

            $executed_from_explorer = ($parentProcess.ProcessName -like "explorer")
        } while ($false)
        if ($executed_from_explorer) {
            $this.print("$msg, press any key to continue . . .")
            cmd /c pause 1>$null
        }
        else {
            $this.println($msg)
        }
    }

    # Get full path without exist check
    [string] realpath($path) {
        return $Global:ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    }

    [string] hash($content) {
        $stringAsStream = [System.IO.MemoryStream]::new()
        $writer = [System.IO.StreamWriter]::new($stringAsStream)
        $writer.write($content)
        $writer.Flush()
        $stringAsStream.Position = 0
        return (Get-FileHash -InputStream $stringAsStream -Algorithm MD5).Hash
    }
}
$b1k = [build1k]::new()

# ---------------------- manifest --------------------
# mode:
# x.y.z+         : >=
# x.y.z          : ==
# *              : any
# x.y.z~x2.y2.z2 : range
$manifest = @{
    # C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Redist\MSVC\14.36.32532\vc_redist.x64.exe
    msvc         = '14.37+'; # cl.exe @link.exe 14.37
    ndk          = 'r23c';
    xcode        = '13.0.0~15.0.0'; # range
    # _EMIT_STL_ERROR(STL1000, "Unexpected compiler version, expected Clang 16.0.0 or newer.");
    llvm         = '16.0.6+'; # clang-cl msvc14.37 require 16.0.0+
    gcc          = '9.0.0+';
    cmake        = '3.28.1+';
    ninja        = '1.11.1+';
    jdk          = '17.0.3+';
    emsdk        = '3.1.51';
    cmdlinetools = '7.0+'; # android cmdlinetools
}

$channels = @{}

# refer to: https://developer.android.com/studio#command-line-tools-only
$cmdlinetools_rev = '10406996'

$android_sdk_tools = @{
    'build-tools' = '34.0.0'
    'platforms' = 'android-34'
}

$options = @{
    p      = $null
    a      = $null
    d      = $null
    cc     = $null
    t      = '' # cb_target
    xt     = 'cmake'
    prefix = $null
    xc     = @()
    xb     = @()
    sdk    = $null
    dll    = $false
}

$optName = $null
foreach ($arg in $args) {
    if (!$optName) {
        if ($arg.StartsWith('-')) {
            $optName = $arg.SubString(1)
        }
    }
    else {
        if ($options.Contains($optName)) {
            $options[$optName] = $arg
        }
        else {
            $b1k.println("Warning: ignore unrecognized option: $optName")
        }
        $optName = $null
    }
}

# translate xtool args
if ($options.xc.GetType() -eq [string]) {
    $options.xc = $options.xc.Split(' ')
}
if ($options.xb.GetType() -eq [string]) {
    $options.xb = $options.xb.Split(' ')
}

$pwsh_ver = $PSVersionTable.PSVersion.ToString()
if ([VersionEx]$pwsh_ver -lt [VersionEx]"7.0") {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$osVer = if ($IsWin) { "Microsoft Windows $([System.Environment]::OSVersion.Version.ToString())" } else { $PSVersionTable.OS }
$hostArch = [System.Runtime.InteropServices.RuntimeInformation, mscorlib]::OSArchitecture.ToString().ToLower()

$b1k.println("PowerShell $pwsh_ver on $osVer")

# determine build target os
$TARGET_OS = $options.p
if (!$TARGET_OS) {
    # choose host target if not specified by command line automatically
    $TARGET_OS = $options.p = $('win32', 'linux', 'osx').Get($HOST_OS)
} else {
    $target_os_norm = @{winuwp = 'winrt'; mac = 'osx' }[$TARGET_OS]
    if ($target_os_norm) {
        $TARGET_OS = $target_os_norm
    }
}

# define some useful global vars
function eval($str, $raw = $false) {
    if (!$raw) {
        return Invoke-Expression "`"$str`""
    } else {
        return Invoke-Expression $str
    }
}

$darwin_sim_suffix = ''
if($TARGET_OS.EndsWith('-sim')) {
    $TARGET_OS = $TARGET_OS.TrimEnd('-sim')
    $darwin_sim_suffix = '-sim'
}
$Global:is_wasm = $TARGET_OS -eq 'wasm'
$Global:Is_win32 = $TARGET_OS -eq 'win32'
$Global:is_winrt = $TARGET_OS -eq 'winrt'
$Global:is_mac = $TARGET_OS -eq 'osx'
$Global:is_linux = $TARGET_OS -eq 'linux'
$Global:is_android = $TARGET_OS -eq 'android'
$Global:is_ios = $TARGET_OS -eq 'ios'
$Global:is_tvos = $TARGET_OS -eq 'tvos'
$Global:is_watchos = $TARGET_OS -eq 'watchos'
$Global:is_win_family = $Global:is_winrt -or $Global:is_win32
$Global:is_darwin_embed_family = $Global:is_ios -or $Global:is_tvos -or $Global:is_watchos
$Global:is_darwin_family = $Global:is_mac -or $Global:is_darwin_embed_family
$Global:is_gh_act = "$env:GITHUB_ACTIONS" -eq 'true'

$Script:cmake_ver = ''

if (!$is_wasm) {
    $TARGET_CPU = $options.a
    if (!$TARGET_CPU) {
        $TARGET_CPU = @{'ios' = 'arm64'; 'tvos' = 'arm64'; 'watchos' = 'arm64'; 'android' = 'arm64'; }[$TARGET_OS]
        if (!$TARGET_CPU) {
            $TARGET_CPU = $hostArch
        }
        $options.a = $TARGET_CPU
    } elseif($TARGET_CPU -eq 'arm') {
        $TARGET_CPU = $options.a = 'armv7'
    }
}
else {
    $TARGET_CPU = $options.a = '*'
}

$Global:is_darwin_embed_device = $Global:is_darwin_embed_family -and $TARGET_CPU -ne 'x64' -and !$darwin_sim_suffix

if (!$setupOnly) {
    $b1k.println("$(Out-String -InputObject $options)")
}

$HOST_OS_NAME = $('windows', 'linux', 'macos').Get($HOST_OS)

# determine toolchain
$TOOLCHAIN = $options.cc
$toolchains = @{
    'win32'   = 'msvc';
    'winrt'   = 'msvc';
    'linux'   = 'gcc';
    'android' = 'clang'; # xcode clang
    'osx'     = 'clang'; # xcode clang
    'ios'     = 'clang'; # xcode clang
    'tvos'    = 'clang'; # xcode clang
    'watchos' = 'clang'; # xcode clang
    'wasm'    = 'clang'; # emcc clang
}
if (!$TOOLCHAIN) {
    $TOOLCHAIN = $toolchains[$TARGET_OS]
}
$TOOLCHAIN_INFO = $TOOLCHAIN.Split('-')
$TOOLCHAIN_VER = $null
if ($TOOLCHAIN_INFO.Count -ge 2) {
    $toolVer = $TOOLCHAIN_INFO[$TOOLCHAIN_INFO.Count - 1]
    if ($toolVer -match "\d+") {
        $TOOLCHAIN_NAME = $TOOLCHAIN_INFO[0..($TOOLCHAIN_INFO.Count - 2)] -join '-'
        $TOOLCHAIN_VER = $toolVer
    }
}
if (!$TOOLCHAIN_VER) {
    $TOOLCHAIN_NAME = $TOOLCHAIN
}

$Global:is_clang = $TOOLCHAIN_NAME -eq 'clang'
$Global:is_msvc = $TOOLCHAIN_NAME -eq 'msvc'

$external_prefix = if ($options.prefix) { $options.prefix } else { Join-Path $HOME '.1kiss' }
if (!$b1k.isdir($external_prefix)) {
    $b1k.mkdirs($external_prefix)
}

$b1k.println("proj_dir=$((Get-Location).Path), external_prefix=$external_prefix")

# load toolset manifest
$manifest_file = Join-Path $myRoot 'manifest.ps1'
if ($b1k.isfile($manifest_file)) {
    . $manifest_file
}

# accept x.y.z-rc1
function version_eq($ver1, $ver2) {
    return $ver1 -eq $ver2
}

# $ver2: accept x.y.z-rc1
function version_ge($ver1, $ver2) {
    $validatedVer = [Regex]::Match($ver1, '(\d+\.)+(-)?(\*|\d+)')
    if ($validatedVer.Success) {
        return [VersionEx]$validatedVer.Value -ge [VersionEx]$ver2
    }
    return $false
}

# $verMain and $verMax not accept x.y.z-rc1
function version_in_range($ver1, $verMin, $verMax) {
    $validatedVer = [Regex]::Match($ver1, '(\d+\.)+(-)?(\*|\d+)')
    if ($validatedVer.Success) {
        $typedVer1 = [VersionEx]$validatedVer.Value
        $typedVerMin = [VersionEx]$verMin
        $typedVerMax = [VersionEx]$verMax
        return $typedVer1 -ge $typedVerMin -and $typedVer1 -le $typedVerMax
    }
    return $false
}

# validate $env:PATH to avoid unexpected shell script behavior
if ([Regex]::Match($env:PATH, "`'|`"").Success) {
    throw "Please remove any `' or `" from your PATH list"
}

# validate cmd follow symlink recurse
function validate_cmd_fs($source, $root) {
    $fileinfo = Get-Item $source
    if (!$fileinfo.Target) {
        if ($source -ne $root) {
            $b1k.println("info: the cmd follow symlink $root ==> $source")
        }
        return $true
    }
    $target = $fileinfo.Target
    if (![IO.Path]::IsPathRooted($target)) {
        # convert symlink target to fullpath
        $target = $b1k.realpath($(Join-Path $(Split-Path $source -Parent) $target))
    }
    if (!$b1k.isfile($target)) {
        $b1k.println("warning: the symlink target $root ==> $target is missing")
        return $false
    }
    if ($target -eq $root) {
        $b1k.println("warning: detected cycle symlink for cmd $root")
        return $true
    }
    return (validate_cmd_fs $target $root)
}

function validate_cmd($source) {
    return (validate_cmd_fs $source $source)
}

function find_cmd($cmd) {
    $cmd_info = (Get-Command $cmd -ErrorAction SilentlyContinue)
    if ($cmd_info -and (validate_cmd $cmd_info.Source)) {
        return $cmd_info
    }

    return $null
}
function find_prog($name, $path = $null, $mode = 'ONLY', $cmd = $null, $params = @('--version'), $silent = $false, $usefv = $false) {
    if ($path) {
        $storedPATH = $env:PATH
        if ($mode -eq 'ONLY') {
            $env:PATH = $path
        }
        elseif ($mode -eq 'BOTH') {
            $env:PATH = "$path$ENV_PATH_SEP$env:PATH"
        }
    }
    else {
        $storedPATH = $null
    }
    if (!$cmd) { $cmd = $name }

    $params = [array]$params

    # try get match expr and preferred ver
    $checkVerCond = $null
    $requiredMin = ''
    $preferredVer = ''
    $requiredVer = $manifest[$name]
    if ($requiredVer) {
        $preferredVer = $null
        if ($requiredVer.EndsWith('+')) {
            $preferredVer = $requiredVer.TrimEnd('+')
            $checkVerCond = '$(version_ge $foundVer $preferredVer)'
        }
        elseif ($requiredVer -eq '*') {
            $checkVerCond = '$True'
            $preferredVer = 'latest'
        }
        else {
            $verArr = $requiredVer.Split('~')
            $isRange = $verArr.Count -gt 1
            $preferredVer = $verArr[$isRange]
            if ($isRange -gt 1) {
                $requiredMin = $verArr[0]
                $checkVerCond = '$(version_in_range $foundVer $requiredMin $preferredVer)'
            }
            else {
                $checkVerCond = '$(version_eq $foundVer $preferredVer)'
            }
        }
        if (!$checkVerCond) {
            throw "Invalid tool $name=$requiredVer in manifest"
        }
    }

    # find command
    $cmd_info = find_cmd $cmd

    # needs restore immidiately since further cmd invoke maybe require system bins
    if ($path) {
        $env:PATH = "$path$ENV_PATH_SEP$storedPATH"
    }

    $found_rets = $null # prog_path,prog_version
    if ($cmd_info) {
        $prog_path = $cmd_info.Source

        if(!$usefv) {
            $verStr = $(. $cmd @params 2>$null) | Select-Object -First 1
            if (!$verStr -or ($verStr.IndexOf('--version') -ne -1)) {
                $verInfo = $cmd_info.Version
                $verStr = "$($verInfo.Major).$($verInfo.Minor).$($verInfo.Build)"
            }

            # can match x.y.z-rc3 or x.y.z-65a239b
            $matchInfo = [Regex]::Match($verStr, '(\d+\.)+(\*|\d+)(\-[a-z0-9]+)?')
            $foundVer = $matchInfo.Value
        } else {
            $foundVer = "$($cmd_info.Version)"
        }
        [void]$requiredMin
        if ($checkVerCond) {
            $matched = Invoke-Expression $checkVerCond
            if ($matched) {
                if (!$silent) { $b1k.println("Using ${name}: $prog_path, version: $foundVer") }
                $found_rets = $prog_path, $foundVer
            }
            else {
                # if (!$silent) { $b1k.println("The installed ${name}: $prog_path, version: $foundVer not match required: $requiredVer") }
                $found_rets = $null, $preferredVer
            }
        }
        else {
            if (!$silent) { $b1k.println("Using ${name}: $prog_path, version: $foundVer") }
            $found_rets = $prog_path, $foundVer
        }
    }
    else {
        if ($preferredVer) {
            # if (!$silent) { $b1k.println("Not found $name, needs install: $preferredVer") }
            $found_rets = $null, $preferredVer
        }
        else {
            throw "Not found $name, and it's not in manifest"
        }
    }

    if ($storedPATH) {
        $env:PATH = $storedPATH
    }

    return $found_rets
}

function exec_prog($prog, $params) {
    # & $prog_name $params
    for ($i = 0; $i -lt $params.Count; $i++) {
        $param = "'"
        $param += $params[$i]
        $param += "'"
        $params[$i] = $param
    }
    $strParams = "$params"
    return Invoke-Expression -Command "$prog $strParams"
}

function download_file($url, $out) {
    if ($b1k.isfile($out)) { return }
    $b1k.println("Downloading $url to $out ...")
    Invoke-WebRequest -Uri $url -OutFile $out
}

function download_and_expand($url, $out, $dest) {
    download_file $url $out
    if ($out.EndsWith('.zip')) {
        try {
            Expand-Archive -Path $out -DestinationPath $dest
        }
        catch {
            Remove-Item $out -Force
            throw "1kiss: Expand archive $out fail, please try again"
        }
    }
    elseif ($out.EndsWith('.tar.gz')) {
        if (!$dest.EndsWith('/')) {
            $b1k.mkdirs($dest)
        }
        tar xf "$out" -C $dest
    }
    elseif ($out.EndsWith('.sh')) {
        chmod 'u+x' "$out"
        $b1k.mkdirs($dest)
    }
}

# setup nuget, not add to path
function setup_nuget() {
    if (!$manifest['nuget']) { return $null }
    $nuget_bin = Join-Path $external_prefix 'nuget'
    $nuget_prog, $nuget_ver = find_prog -name 'nuget' -path $nuget_bin -mode 'BOTH' -silent $true
    if (!$nuget_prog) {
        $b1k.rmdirs($nuget_bin)
        $b1k.mkdirs($nuget_bin)

        $nuget_prog = Join-Path $nuget_bin 'nuget.exe'
        download_file "https://dist.nuget.org/win-x86-commandline/v$nuget_ver/nuget.exe" $nuget_prog
        if (!$b1k.isfile($nuget_prog)) {
            throw "Install nuget fail"
        }
    }

    if ($env:PATH.IndexOf($nuget_bin) -eq -1) {
        $env:PATH = "$nuget_bin$ENV_PATH_SEP$env:PATH"
    }
    $b1k.println("Using nuget: $nuget_prog, version: $nuget_ver")
    return $nuget_prog
}

# setup glslcc, not add to path
function setup_glslcc() {
    if (!$manifest['glslcc']) { return $null }
    $glslcc_bin = Join-Path $external_prefix 'glslcc'
    $glslcc_prog, $glslcc_ver = find_prog -name 'glslcc' -path $glslcc_bin -mode 'BOTH'
    if ($glslcc_prog) {
        return $glslcc_prog
    }

    $suffix = $('win64.zip', 'linux.tar.gz', 'osx.tar.gz').Get($HOST_OS)
    $b1k.rmdirs($glslcc_bin)
    $glslcc_pkg = Join-Path $external_prefix "glslcc-$suffix"
    $b1k.del($glslcc_pkg)

    download_and_expand "https://github.com/axmolengine/glslcc/releases/download/v$glslcc_ver/glslcc-$glslcc_ver-$suffix" "$glslcc_pkg" $glslcc_bin

    $glslcc_prog = (Join-Path $glslcc_bin "glslcc$exeSuffix")
    if ($b1k.isfile($glslcc_prog)) {
        $b1k.println("Using glslcc: $glslcc_prog, version: $glslcc_ver")
        return $glslcc_prog
    }

    throw "Install glslcc fail"
}

function setup_ninja() {
    if (!$manifest['ninja']) { return $null }
    $suffix = $('win', 'linux', 'mac').Get($HOST_OS)
    $ninja_bin = Join-Path $external_prefix 'ninja'
    $ninja_prog, $ninja_ver = find_prog -name 'ninja'
    if ($ninja_prog) {
        return $ninja_prog
    }

    $ninja_prog, $ninja_ver = find_prog -name 'ninja' -path $ninja_bin -silent $true
    if (!$ninja_prog) {
        $ninja_pkg = "$external_prefix/ninja-$suffix.zip"
        $b1k.rmdirs($ninja_bin)
        $b1k.del($ninja_pkg)

        download_and_expand "https://github.com/ninja-build/ninja/releases/download/v$ninja_ver/ninja-$suffix.zip" $ninja_pkg "$external_prefix/ninja/"
    }
    if ($env:PATH.IndexOf($ninja_bin) -eq -1) {
        $env:PATH = "$ninja_bin$ENV_PATH_SEP$env:PATH"
    }
    $ninja_prog = (Join-Path $ninja_bin "ninja$exeSuffix")

    $b1k.println("Using ninja: $ninja_prog, version: $ninja_ver")
    return $ninja_prog
}

# setup cmake
function setup_cmake($skipOS = $false) {
    $cmake_prog, $cmake_ver = find_prog -name 'cmake'
    if ($cmake_prog -and (!$skipOS -or $cmake_prog.IndexOf($myRoot) -ne -1)) {
        return $cmake_prog, $cmake_ver
    }

    $cmake_root = $(Join-Path $external_prefix 'cmake')
    $cmake_bin = Join-Path $cmake_root 'bin'
    $cmake_prog, $cmake_ver = find_prog -name 'cmake' -path $cmake_bin -mode 'ONLY' -silent $true
    if (!$cmake_prog) {
        $b1k.rmdirs($cmake_root)

        $cmake_suffix = @(".zip", ".sh", ".tar.gz").Get($HOST_OS)
        if ($HOST_OS -ne $HOST_MAC) {
            $cmake_pkg_name = "cmake-$cmake_ver-$HOST_OS_NAME-x86_64"
        }
        else {
            $cmake_pkg_name = "cmake-$cmake_ver-$HOST_OS_NAME-universal"
        }

        $cmake_pkg_path = Join-Path $external_prefix "$cmake_pkg_name$cmake_suffix"

        $assemble_url = $channels['cmake']
        if (!$assemble_url) {
            $cmake_url = "https://github.com/Kitware/CMake/releases/download/v$cmake_ver/$cmake_pkg_name$cmake_suffix"
        }
        else {
            $cmake_url = & $assemble_url -FileName "$cmake_pkg_name$cmake_suffix"
        }

        $cmake_dir = Join-Path $external_prefix $cmake_pkg_name
        if ($IsMacOS) {
            $cmake_app_contents = Join-Path $cmake_dir 'CMake.app/Contents'
        }
        if (!$b1k.isdir($cmake_dir)) {
            download_and_expand "$cmake_url" "$cmake_pkg_path" $external_prefix/
        }

        if ($b1k.isdir($cmake_dir)) {
            $cmake_root0 = $cmake_dir
            if ($IsMacOS) {
                $cmake_app_contents = Join-Path $cmake_dir 'CMake.app/Contents'
                if ($b1k.isdir($cmake_app_contents)) {
                    $cmake_root0 = $cmake_app_contents
                }
                sudo xattr -r -d com.apple.quarantine "$cmake_root0/bin/cmake"
            }
            $b1k.mv($cmake_root0, $cmake_root)

            if ($b1k.isdir($cmake_dir)) {
                $b1k.rmdirs($cmake_dir)
            }
        }
        elseif ($IsLinux) {
            $b1k.mkdirs($cmake_root)
            & "$cmake_pkg_path" '--skip-license' '--exclude-subdir' "--prefix=$cmake_root" 1>$null 2>$null
        }

        $cmake_prog, $_ = find_prog -name 'cmake' -path $cmake_bin -silent $true
        if (!$cmake_prog) {
            throw "Install cmake $cmake_ver fail"
        }

        $b1k.println("Using cmake: $cmake_prog, version: $cmake_ver")
    }

    if (($null -ne $cmake_bin) -and ($env:PATH.IndexOf($cmake_bin) -eq -1)) {
        $env:PATH = "$cmake_bin$ENV_PATH_SEP$env:PATH"
    }
    return $cmake_prog, $cmake_ver
}

function ensure_cmake_ninja($cmake_prog, $ninja_prog) {
    # ensure ninja in cmake_bin
    $cmake_bin = Split-Path $cmake_prog -Parent
    $cmake_ninja_prog, $__ = find_prog -name 'ninja' -path $cmake_bin -mode 'ONLY' -silent $true
    if (!$cmake_ninja_prog) {
        $ninja_symlink_target = Join-Path $cmake_bin (Split-Path $ninja_prog -Leaf)
        # try link ninja exist cmake bin directory
        & "$myRoot\fsync.ps1" -s $ninja_prog -d $ninja_symlink_target -l $true 2>$null

        if(!$? -and $IsWin) { # try runas admin again
            $mklink_args = "-Command ""& ""$myRoot\fsync.ps1"" -s '$ninja_prog' -d '$ninja_symlink_target' -l `$true 2>`$null"""
            Write-Host "mklink_args={$mklink_args}"
            Start-Process powershell -ArgumentList $mklink_args -WindowStyle Hidden -Wait -Verb runas
        }
    }
    return $?
}

function setup_nsis() {
    if (!$manifest['nsis']) { return $null }
    $nsis_bin = Join-Path $external_prefix "nsis"
    $nsis_prog, $nsis_ver = find_prog -name 'nsis' -cmd 'makensis' -params '/VERSION'
    if ($nsis_prog) {
        return $nsis_prog
    }

    $nsis_prog, $nsis_ver = find_prog -name 'nsis' -cmd 'makensis' -params '/VERSION' -path $nsis_bin -silent $true
    if (!$nsis_prog) {
        $b1k.rmdirs($nsis_bin)
        
        download_and_expand "https://nchc.dl.sourceforge.net/project/nsis/NSIS%203/$nsis_ver/nsis-$nsis_ver.zip" "$external_prefix/nsis-$nsis_ver.zip" "$external_prefix"
        $nsis_dir = "$nsis_bin-$nsis_ver"
        if ($b1k.isdir($nsis_dir)) {
            $b1k.mv($nsis_dir, $nsis_bin)
        }
    }

    if ($env:PATH.IndexOf($nsis_bin) -eq -1) {
        $env:PATH = "$nsis_bin$ENV_PATH_SEP$env:PATH"
    }
    $nsis_prog = (Join-Path $nsis_bin "makensis$exeSuffix")

    $b1k.println("Using nsis: $nsis_prog, version: $nsis_ver")
    return $nsis_prog
}

function setup_nasm() {
    if (!$manifest['nasm']) { return $null }
    $nasm_prog, $nasm_ver = find_prog -name 'nasm' -path "$external_prefix/nasm" -mode 'BOTH' -silent $true

    if (!$nasm_prog) {
        if ($IsWindows) {
            $nasm_bin = Join-Path $external_prefix "nasm-$nasm_ver"

            if (!(Test-Path $nasm_bin -PathType Container)) {
                download_and_expand "https://www.nasm.us/pub/nasm/releasebuilds/$nasm_ver/win64/nasm-$nasm_ver-win64.zip" "$external_prefix/nasm-$nasm_ver-win64.zip" "$external_prefix"
            }
            if ($env:PATH.IndexOf($nsis_bin) -eq -1) {
                $env:PATH = "$nasm_bin$ENV_PATH_SEP$env:PATH"
            }
        }
        elseif ($IsLinux) {
            if ($(which dpkg)) {
                sudo apt-get install nasm
            }
        }
        elseif ($IsMacOS) {
            brew install nasm
        }
    }

    $nasm_prog, $nasm_ver = find_prog -name 'nasm' -path "$external_prefix/nasm" -mode 'BOTH' -silent $true
    if ($nasm_prog) {
        $b1k.println("Using nasm: $nasm_prog, version: $nasm_ver")
    }
}

function setup_jdk() {
    if (!$manifest['jdk']) { return $null }
    $suffix = $('windows-x64.zip', 'linux-x64.tar.gz', 'macOS-x64.tar.gz').Get($HOST_OS)
    $javac_prog, $jdk_ver = find_prog -name 'jdk' -cmd 'javac'
    if ($javac_prog) {
        return $javac_prog
    }

    $jdk_root = Join-Path $external_prefix "jdk"
    $java_home = if (!$IsMacOS) { $jdk_root } else { Join-Path $jdk_root 'Contents/Home' }
    $jdk_bin = Join-Path $java_home 'bin'

    $javac_prog, $jdk_ver = find_prog -name 'jdk' -cmd 'javac' -path $jdk_bin -silent $true
    if (!$javac_prog) {
        $b1k.rmdirs($jdk_root)

        # refer to https://learn.microsoft.com/en-us/java/openjdk/download
        download_and_expand "https://aka.ms/download-jdk/microsoft-jdk-$jdk_ver-$suffix" "$external_prefix/microsoft-jdk-$jdk_ver-$suffix" "$external_prefix/"

        # move to plain folder name
        $folderName = (Get-ChildItem -Path $external_prefix -Filter "jdk-$jdk_ver+*").Name
        if ($folderName) {
            $b1k.mv("$external_prefix/$folderName", $jdk_root)
        }
    }

    $env:JAVA_HOME = $java_home
    $env:CLASSPATH = ".;$java_home\lib\dt.jar;$java_home\lib\tools.jar"
    if ($env:PATH.IndexOf($jdk_bin) -eq -1) {
        $env:PATH = "$jdk_bin$ENV_PATH_SEP$env:PATH"
    }
    $javac_prog = find_prog -name 'jdk' -cmd 'javac' -path $jdk_bin -mode 'ONLY' -silent $true
    if (!$javac_prog) {
        throw "Install jdk $jdk_ver fail"
    }

    $b1k.println("Using jdk: $javac_prog, version: $jdk_ver")

    return $javac_prog
}

# setup llvm for windows only
function setup_llvm() {
    if (!$manifest.Contains('llvm')) { return $null }
    $clang_prog, $clang_ver = find_prog -name 'llvm' -cmd "clang"
    if (!$clang_prog) {
        $llvm_root = Join-Path $external_prefix 'LLVM'
        $llvm_bin = Join-Path $llvm_root 'bin'
        $clang_prog, $clang_ver = find_prog -name 'llvm' -cmd "clang" -path $llvm_bin -silent $true
        if (!$clang_prog) {
            # ensure 7z_prog
            $7z_cmd_info = Get-Command '7z' -ErrorAction SilentlyContinue
            if ($7z_cmd_info) {
                $7z_prog = $7z_cmd_info.Path
            }
            else {
                $7z_prog = Join-Path $external_prefix '7z2301-x64\7z.exe'
                $7z_pkg_out = Join-Path $external_prefix '7z2301-x64.zip'
                if (!(Test-Path $7z_prog -PathType Leaf)) {
                    # https://www.7-zip.org/download.html
                    download_and_expand -url 'https://github.com/simdsoft/1kiss/releases/download/devtools/7z2301-x64.zip' -out $7z_pkg_out $external_prefix/
                }
            }

            if (!(Test-Path $7z_prog -PathType Leaf)) {
                throw "setup 7z fail which is required for setup llvm clang!"
            }

            # download llvm clang and install extract it at prefix
            download_file "https://github.com/llvm/llvm-project/releases/download/llvmorg-${clang_ver}/LLVM-${clang_ver}-win64.exe" "$external_prefix\LLVM-${clang_ver}-win64.exe"
            $b1k.mkdirs($llvm_root)
            & $7z_prog x "$external_prefix\LLVM-${clang_ver}-win64.exe" "-o$llvm_root" -y | Out-Host

            $clang_prog, $clang_ver = find_prog -name 'llvm' -cmd "clang" -path $llvm_bin -silent $true
            if (!$clang_prog) {
                throw "setup $clang_ver fail"
            }
        }

        $b1k.println("Using llvm: $clang_prog, version: $clang_ver")

        # add our llvm root to PATH temporary
        if (($env:PATH.IndexOf($llvm_bin) -eq -1)) {
            $env:PATH = "$llvm_bin$ENV_PATH_SEP$env:PATH"
        }
    }
}

function setup_android_sdk() {
    if (!$manifest['ndk']) { return $null }
    # setup ndk
    $ndk_ver = $TOOLCHAIN_VER
    if (!$ndk_ver) {
        $ndk_ver = $manifest['ndk']
    }

    $IsGraterThan = if ($ndk_ver.EndsWith('+')) { '+' } else { $null }
    if ($IsGraterThan) {
        $ndk_ver = $ndk_ver.Substring(0, $ndk_ver.Length - 1)
    }

    $my_sdk_root = Join-Path $external_prefix 'adt/sdk'

    $sdk_dirs = @("$env:ANDROID_HOME", "$env:ANDROID_SDK_ROOT", $my_sdk_root)

    $ndk_minor_base = [int][char]'a'

    # looking up require ndk installed in exists sdk roots
    $sdk_root = $null
    foreach ($sdk_dir in $sdk_dirs) {
        if (!$sdk_dir -or !(Test-Path $sdk_dir -PathType Container)) {
            continue
        }
        $b1k.println("Looking require $ndk_ver$IsGraterThan in $sdk_dir")
        $sdk_root = $sdk_dir
        $ndk_root = $null

        $ndk_major = ($ndk_ver -replace '[^0-9]', '')
        $ndk_minor_off = "$ndk_major".Length + 1
        $ndk_minor = if ($ndk_minor_off -lt $ndk_ver.Length) { "$([int][char]$ndk_ver.Substring($ndk_minor_off) - $ndk_minor_base)" } else { '0' }
        $ndk_rev_base = "$ndk_major.$ndk_minor"

        $ndk_parent = Join-Path $sdk_dir 'ndk'
        if (!$b1k.isdir($ndk_parent)) {
            continue
        }

        # find ndk in sdk
        $ndks = [ordered]@{}
        $ndk_rev_max = '0.0'
        foreach ($item in $(Get-ChildItem -Path "$ndk_parent")) {
            $ndkDir = $item.FullName
            $sourceProps = "$ndkDir/source.properties"
            if ($b1k.isfile($sourceProps)) {
                $verLine = $(Get-Content $sourceProps | Select-Object -Index 1)
                $ndk_rev = $($verLine -split '=').Trim()[1].split('.')[0..1] -join '.'
                $ndks.Add($ndk_rev, $ndkDir)
                if ($ndk_rev_max -le $ndk_rev) {
                    $ndk_rev_max = $ndk_rev
                }
            }
        }
        if ($IsGraterThan) {
            if ($ndk_rev_max -ge $ndk_rev_base) {
                $ndk_root = $ndks[$ndk_rev_max]
            }
        }
        else {
            $ndk_root = $ndks[$ndk_rev_base]
        }

        if ($null -ne $ndk_root) {
            $b1k.println("Found $ndk_root in $sdk_root ...")
            break
        }
    }

    if (!$b1k.isdir("$ndk_root")) {
        $sdkmanager_prog, $sdkmanager_ver = $null, $null
        if ($b1k.isdir($sdk_root)) {
            $cmdlinetools_bin = Join-Path $sdk_root 'cmdline-tools/latest/bin'
            $sdkmanager_prog, $sdkmanager_ver = (find_prog -name 'cmdlinetools' -cmd 'sdkmanager' -path $cmdlinetools_bin -params "--version", "--sdk_root=$sdk_root")
        }
        else {
            $sdk_root = Join-Path $external_prefix 'adt/sdk'
            if (!$b1k.isdir($sdk_root)) {
                $b1k.mkdirs($sdk_root)
            }
        }

        if (!$sdkmanager_prog) {
            $cmdlinetools_bin = Join-Path $external_prefix 'cmdline-tools/bin'
            $sdkmanager_prog, $sdkmanager_ver = (find_prog -name 'cmdlinetools' -cmd 'sdkmanager' -path $cmdlinetools_bin -params "--version", "--sdk_root=$sdk_root")
            $suffix = $('win', 'linux', 'mac').Get($HOST_OS)
            if (!$sdkmanager_prog) {
                $b1k.println("Installing cmdlinetools version: $sdkmanager_ver ...")

                $cmdlinetools_pkg_name = "commandlinetools-$suffix-$($cmdlinetools_rev)_latest.zip"
                $cmdlinetools_pkg_path = Join-Path $external_prefix $cmdlinetools_pkg_name
                $cmdlinetools_url = "https://dl.google.com/android/repository/$cmdlinetools_pkg_name"
                download_file $cmdlinetools_url $cmdlinetools_pkg_path
                Expand-Archive -Path $cmdlinetools_pkg_path -DestinationPath "$external_prefix/"
                $sdkmanager_prog, $_ = (find_prog -name 'cmdlinetools' -cmd 'sdkmanager' -path $cmdlinetools_bin -params "--version", "--sdk_root=$sdk_root" -silent $True)
                if (!$sdkmanager_prog) {
                    throw "Install cmdlinetools version: $sdkmanager_ver fail"
                }
            }
        }

        $matchInfos = (exec_prog -prog $sdkmanager_prog -params "--sdk_root=$sdk_root", '--list' | Select-String 'ndk;')
        if ($null -ne $matchInfos -and $matchInfos.Count -gt 0) {
            $b1k.println("Not found suitable android ndk, installing ...")

            $ndks = @{}
            foreach ($matchInfo in $matchInfos) {
                $fullVer = $matchInfo.Line.Trim().Split(' ')[0] # "ndk;23.2.8568313"
                $verNums = $fullVer.Split(';')[1].Split('.')
                $ndkVer = 'r'
                $ndkVer += $verNums[0]

                $ndk_minor = [int]$verNums[1]
                if ($ndk_minor -gt 0) {
                    $ndkVer += [char]($ndk_minor_base + $ndk_minor)
                }
                if (!$ndks.Contains($ndkVer)) {
                    $ndks.Add($ndkVer, $fullVer)
                }
            }

            $ndkFullVer = $ndks[$ndk_ver]

            ((1..10 | ForEach-Object { "yes"; Start-Sleep -Milliseconds 100 }) | . $sdkmanager_prog --licenses --sdk_root=$sdk_root) | Out-Host
            if (!$ndkOnly) {
                exec_prog -prog $sdkmanager_prog -params '--verbose', "--sdk_root=$sdk_root", 'platform-tools', 'cmdline-tools;latest', "platforms;$($android_sdk_tools['platforms'])", "build-tools;$($android_sdk_tools['build-tools'])", $ndkFullVer | Out-Host
            }
            else {
                exec_prog -prog $sdkmanager_prog -params '--verbose', "--sdk_root=$sdk_root", $ndkFullVer | Out-Host
            }
            $fullVer = $ndkFullVer.Split(';')[1]
            $ndk_root = (Resolve-Path -Path "$sdk_root/ndk/$fullVer").Path
        }
    }

    return $sdk_root, $ndk_root
}

# enable emsdk emcmake
function setup_emsdk() {
    $emcc_prog, $emcc_ver = find_prog -name 'emsdk' -cmd 'emcc' -silent $true
    if (!$emcc_prog) {
        # no suitable emcc toolchain found, use official emsdk to setup
        $b1k.println('Not found emcc toolchain in $env:PATH, setup emsdk ...')
        $emsdk_cmd = (Get-Command emsdk -ErrorAction SilentlyContinue)
        if (!$emsdk_cmd) {
            $emsdk_root = Join-Path $external_prefix 'emsdk'
            if (!(Test-Path $emsdk_root -PathType Container)) {
                git clone 'https://github.com/emscripten-core/emsdk.git' $emsdk_root
            }
            else {
                git -C $emsdk_root pull
            }
        }
        else {
            $emsdk_root = Split-Path $emsdk_cmd.Source -Parent
        }

        $emcmake = (Get-Command emcmake -ErrorAction SilentlyContinue)
        if (!$emcmake) {
            $emsdk_ver = $manifest['emsdk']
            Push-Location $emsdk_root
            ./emsdk install $emsdk_ver
            ./emsdk activate $emsdk_ver
            . ./emsdk_env.ps1
            Pop-Location
        }
    }
    else {
        $b1k.println("Using emcc: $emcc_prog, version: $emcc_ver")
    }
}


function setup_msvc() {
    $cl_prog, $cl_ver = find_prog -name 'msvc' -cmd 'cl' -silent $true -usefv $true
    if (!$cl_prog) {
        if ($VS_INST) {
            Import-Module "$VS_PATH\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
            Enter-VsDevShell -VsInstanceId $VS_INST.instanceId -SkipAutomaticLocation -DevCmdArguments "-arch=$target_cpu -host_arch=x64 -no_logo"

            # msvc14x support
            $use_msvcr14x = $null
            if ([bool]::TryParse($env:use_msvcr14x, [ref]$use_msvcr14x) -and $use_msvcr14x) {
                if ("$env:LIB".IndexOf('msvcr14x') -eq -1) {
                    $msvcr14x_root = $env:msvcr14x_ROOT
                    $env:Platform = $target_cpu
                    Invoke-Expression -Command "$msvcr14x_root\msvcr14x_nmake.ps1"
                }
            
                println "LIB=$env:LIB"
            }

            $cl_prog, $cl_ver = find_prog -name 'msvc' -cmd 'cl' -silent $true -usefv $true
            $b1k.println("Using msvc: $cl_prog, version: $cl_ver")
        } else {
            throw "Visual Studio not installed!"
        }
    }
}

# google gn build system, current windows only for build angleproject/dawn on windows
function setup_gclient() {
    if (!$ninja_prog) {
        $ninja_prog = setup_ninja
    }

    if ($Global:is_win_family) {
        setup_msvc
    }

    # setup gclient tool
    # download depot_tools
    # git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git $gclient_dir
    $gclient_dir = Join-Path $external_prefix 'depot_tools'
    if(!(Test-Path $gclient_dir -PathType Container)) {
        if ($IsWin) {
            $b1k.mkdirs($gclient_dir)
            Invoke-WebRequest -Uri "https://storage.googleapis.com/chrome-infra/depot_tools.zip" -OutFile "${gclient_dir}.zip"
            Expand-Archive -Path "${gclient_dir}.zip" -DestinationPath $gclient_dir
        } else {
            git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git $gclient_dir
        }

    }

    if ($env:PATH.IndexOf($gclient_dir) -eq -1) {
        $env:PATH = "${gclient_dir}$ENV_PATH_SEP${env:PATH}"
    }
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN = 0
}

#
# Find latest installed: Visual Studio 12 2013 +
# installationVersion
# instanceId EnterDevShell can use it
# result:
#   $Global:VS_VERSION
#   $Global:VS_INST
#   $Global:VS_PATH
#
$Global:VS_VERSION = $null
$Global:VS_PATH = $null
$Global:VS_INST = $null
function find_vs_latest() {
    $vs_version = [VersionEx]'12.0'
    if (!$Global:VS_INST) {
        $VSWHERE_EXE = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'

        $vs_installs = ConvertFrom-Json "$(&$VSWHERE_EXE -version '12.0' -format 'json')"
        $ErrorActionPreference = $eap

        if($vs_installs) {
            $vs_inst_latest = $null
            foreach($vs_inst in $vs_installs) {
                $inst_ver = [VersionEx]$vs_inst.installationVersion
                if ($vs_version -lt $inst_ver) {
                    $vs_version = $inst_ver
                    $vs_inst_latest = $vs_inst
                }
            }
            $Global:VS_PATH = $vs_inst_latest.installationPath
            $Global:VS_INST = $vs_inst_latest
        }
    }
    $Global:VS_VERSION = $vs_version
}

# preprocess methods:
#   <param>-inputOptions</param> [CMAKE_OPTIONS]
function preprocess_win([string[]]$inputOptions) {
    $outputOptions = $inputOptions

    if ($options.sdk) {
        $outputOptions += "-DCMAKE_SYSTEM_VERSION=$($options.sdk)"
    }

    if ($Global:is_msvc) {
        # Generate vs2019 on github ci
        # Determine arch name
        $arch = if ($options.a -eq 'x86') { 'Win32' } else { $options.a }

        # arch
        if ($VS_VERSION -ge [VersionEx]'16.0') {
            $outputOptions += '-A', $arch
            if ($TOOLCHAIN_VER) {
                $outputOptions += "-Tv$TOOLCHAIN_VER"
            }
        }
        else {
            $gens = @{
                '120' = 'Visual Studio 12 2013';
                '140' = 'Visual Studio 14 2015'
                "150" = 'Visual Studio 15 2017';
            }
            $Script:cmake_generator = $gens[$TOOLCHAIN_VER]
            if (!$Script:cmake_generator) {
                throw "Unsupported toolchain: $TOOLCHAIN"
            }
            if ($options.a -eq "x64") {
                $Script:cmake_generator += ' Win64'
            }
        }

        # platform
        if ($Global:is_winrt) {
            '-DCMAKE_SYSTEM_NAME=WindowsStore', '-DCMAKE_SYSTEM_VERSION=10.0'
        }

        if ($options.dll) {
            $outputOptions += '-DBUILD_SHARED_LIBS=TRUE'
        }
    }
    elseif ($Global:is_clang) {
        $outputOptions += '-DCMAKE_C_COMPILER=clang', '-DCMAKE_CXX_COMPILER=clang++'
        $Script:cmake_generator = 'Ninja Multi-Config'
    }
    else {
        # Generate mingw
        $Script:cmake_generator = 'Ninja Multi-Config'
    }
    return $outputOptions
}

function preprocess_linux([string[]]$inputOptions) {
    $outputOptions = $inputOptions
    if ($Global:is_clang) {
        $outputOptions += '-DCMAKE_C_COMPILER=clang', '-DCMAKE_CXX_COMPILER=clang++'
    }
    return $outputOptions
}

$ninja_prog = $null
$is_gradlew = $options.xt.IndexOf('gradlew') -ne -1
function preprocess_andorid([string[]]$inputOptions) {
    $outputOptions = $inputOptions

    $t_archs = @{arm64 = 'arm64-v8a'; armv7 = 'armeabi-v7a'; x64 = 'x86_64'; x86 = 'x86'; }

    if ($is_gradlew) {
        if ($options.a.GetType() -eq [object[]]) {
            $archlist = [string[]]$options.a
        }
        else {
            $archlist = $options.a.Split(';')
        }
        for ($i = 0; $i -lt $archlist.Count; ++$i) {
            $arch = $archlist[$i]
            $archlist[$i] = $t_archs[$arch]
        }

        $archs = $archlist -join ':' # TODO: modify gradle, split by ';'

        $outputOptions += "-P__1K_CMAKE_VERSION=$($Script:cmake_ver.TrimLast('-'))"
        $outputOptions += "-P__1K_ARCHS=$archs"
        $outputOptions += '--parallel', '--info'
    }
    else {
        if (!$ndk_root) {
            throw "ndk_root not specified!"
        }
        $cmake_toolchain_file = Join-Path $ndk_root 'build/cmake/android.toolchain.cmake'
        $arch = $t_archs[$options.a]
        $outputOptions += "-DCMAKE_TOOLCHAIN_FILE=$cmake_toolchain_file", "-DANDROID_ABI=$arch"
        # If set to ONLY, then only the roots in CMAKE_FIND_ROOT_PATH will be searched
        # If set to BOTH, then the host system paths and the paths in CMAKE_FIND_ROOT_PATH will be searched
        # If set to NEVER, then the roots in CMAKE_FIND_ROOT_PATH will be ignored and only the host system root will be used
        # CMAKE_FIND_ROOT_PATH is preferred for additional search directories when cross-compiling
        # $outputOptions += '-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH'
        # $outputOptions += '-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH'
        # $outputOptions += '-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH'
        # by default, we want find host program only when cross-compiling
        $outputOptions += '-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER'
    }

    return $outputOptions
}

function preprocess_osx([string[]]$inputOptions) {
    $outputOptions = $inputOptions
    $arch = $options.a
    if ($arch -eq 'x64') {
        $arch = 'x86_64'
    }

    $outputOptions += "-DCMAKE_OSX_ARCHITECTURES=$arch"
    return $outputOptions
}

# build ios famliy (ios,tvos,watchos)
function preprocess_ios([string[]]$inputOptions) {
    $outputOptions = $inputOptions
    $arch = $options.a
    if ($arch -eq 'x64') {
        $arch = 'x86_64'
    }
    if (!$cmake_toolchain_file) {
        $cmake_toolchain_file = Join-Path $myRoot 'ios.cmake'
        $outputOptions += "-DCMAKE_TOOLCHAIN_FILE=$cmake_toolchain_file", "-DARCHS=$arch"
        if ($Global:is_tvos) {
            $outputOptions += '-DPLAT=tvOS'
        }
        elseif ($Global:is_watchos) {
            $outputOptions += '-DPLAT=watchOS'
        }
    }
    return $outputOptions
}

function preprocess_wasm([string[]]$inputOptions) {
    return $inputOptions
}

function validHostAndToolchain() {
    $appleTable = @{
        'host'      = @{'macos' = $True };
        'toolchain' = @{'clang' = $True; };
    };
    $validTable = @{
        'win32'   = @{
            'host'      = @{'windows' = $True };
            'toolchain' = @{'msvc' = $True; 'clang' = $True; 'gcc' = $True };
        };
        'winrt'   = @{
            'host'      = @{'windows' = $True };
            'toolchain' = @{'msvc' = $True; };
        };
        'linux'   = @{
            'host'      = @{'linux' = $True };
            'toolchain' = @{'gcc' = $True; 'clang' = $True };
        };
        'android' = @{
            'host'      = @{'windows' = $True; 'linux' = $True; 'macos' = $True };
            'toolchain' = @{'clang' = $True; };
        };
        'osx'     = $appleTable;
        'ios'     = $appleTable;
        'tvos'    = $appleTable;
        'watchos' = $appleTable;
        'wasm'    = @{
            'host'      = @{'windows' = $True; 'linux' = $True; 'macos' = $True };
            'toolchain' = @{'clang' = $True; };
        };
    }
    $validInfo = $validTable[$TARGET_OS]
    $validOS = $validInfo.host[$HOST_OS_NAME]
    if (!$validOS) {
        throw "Can't build target $TARGET_OS on $HOST_OS_NAME"
    }
    $validToolchain = $validInfo.toolchain[$TOOLCHAIN_NAME]
    if (!$validToolchain) {
        throw "Can't build target $TARGET_OS with toolchain $TOOLCHAIN_NAME"
    }
}

$proprocessTable = @{
    'win32'   = ${function:preprocess_win};
    'winrt'   = ${function:preprocess_win};
    'linux'   = ${function:preprocess_linux};
    'android' = ${function:preprocess_andorid};
    'osx'     = ${function:preprocess_osx};
    'ios'     = ${function:preprocess_ios};
    'tvos'    = ${function:preprocess_ios};
    'watchos' = ${function:preprocess_ios};
    'wasm'    = ${Function:preprocess_wasm};
}

validHostAndToolchain

########## setup build tools if not installed #######

$null = setup_glslcc

$cmake_prog,$Script:cmake_ver = setup_cmake

if ($Global:is_win_family) {
    find_vs_latest
    $nuget_prog = setup_nuget
}

if ($Global:is_win32) {
    $nsis_prog = setup_nsis
    if (!$Global:is_msvc) {
        $ninja_prog = setup_ninja
    }
    if ($Global:is_clang) {
        $null = setup_llvm
    }
}
elseif ($Global:is_android) {
    $ninja_prog = setup_ninja
    # ensure ninja in cmake_bin
    if (!(ensure_cmake_ninja $cmake_prog $ninja_prog)) {
        $cmake_prog,$Script:cmake_ver = setup_cmake -Force
        if (!(ensure_cmake_ninja $cmake_prog $ninja_prog)) {
            $b1k.println("Ensure ninja in cmake bin directory fail")
        }
    }

    $null = setup_jdk # setup android sdk cmdlinetools require jdk
    $sdk_root, $ndk_root = setup_android_sdk
    $env:ANDROID_HOME = $sdk_root
    $env:ANDROID_NDK = $ndk_root
    # sync ndk env vars for some library required, i.e. will fix openssl issues:
    # no NDK xxx-linux-android-gcc on $PATH at (eval 10) line 142.
    # Note: github action vm also have follow env vars
    $env:ANDROID_NDK_HOME = $ndk_root
    $env:ANDROID_NDK_ROOT = $ndk_root

    $ndk_host = @('windows', 'linux', 'darwin').Get($HOST_OS)
    $env:ANDROID_NDK_BIN = Join-Path $ndk_root "toolchains/llvm/prebuilt/$ndk_host-x86_64/bin"
    function active_ndk_toolchain() {
        if ($env:PATH.IndexOf($env:ANDROID_NDK_BIN) -eq -1) {
            $env:PATH = "$env:ANDROID_NDK_BIN$ENV_PATH_SEP$env:PATH"
        }
        $clang_prog, $clang_ver = find_prog -name 'clang'
    }
}
elseif ($Global:is_wasm) {
    $ninja_prog = setup_ninja
    . setup_emsdk
}

$is_host_target = $Global:is_win32 -or $Global:is_linux -or $Global:is_mac

if (!$setupOnly) {
    $BUILD_DIR = $null

    function resolve_out_dir($prefix, $category) {
        if (!$prefix) {
            $prefix = $category
        }
        if ($is_host_target) {
            $out_dir = "${prefix}_${TARGET_CPU}"
        }
        else {
            $out_dir = "${prefix}_${TARGET_OS}"
            if ($TARGET_CPU -ne '*') {
                $out_dir += "_$TARGET_CPU"
            }
        }
        return $b1k.realpath($out_dir)
    }

    $stored_cwd = $(Get-Location).Path
    if ($options.d) {
        Set-Location $options.d
    }

    if ($options.xt -ne 'gn') {
        # parsing build optimize flag from build_options
        $buildOptions = [array]$options.xb
        $nopts = $buildOptions.Count
        $optimize_flag = $null
        for ($i = 0; $i -lt $nopts; ++$i) {
            $optv = $buildOptions[$i]
            switch ($optv) {
                '--config' {
                    $optimize_flag = $buildOptions[$i++ + 1]
                }
                '--target' {
                    $cmake_target = $buildOptions[$i++ + 1]
                }
            }
        }

        $BUILD_ALL_OPTIONS = @()
        $BUILD_ALL_OPTIONS += $buildOptions
        if (!$optimize_flag) {
            if ($cmake_optimize_flags) {
                $optimize_flag = $cmake_optimize_flags[$TARGET_OS]
            }
            if (!$optimize_flag) {
                $optimize_flag = 'Release'
            }
            $BUILD_ALL_OPTIONS += '--config', $optimize_flag
        }

        # enter building steps
        $b1k.println("Building target $TARGET_OS on $HOST_OS_NAME with toolchain $TOOLCHAIN ...")

        # step1. preprocess cross make options
        $CONFIG_ALL_OPTIONS = [array]$(& $proprocessTable[$TARGET_OS] -inputOptions @() )

        if (!$CONFIG_ALL_OPTIONS) {
            $CONFIG_ALL_OPTIONS = @()
        }

        # determine generator, build_dir, inst_dir for non gradlew projects
        if (!$is_gradlew) {
            if (!$cmake_generator -and !$TARGET_OS.StartsWith('win')) {
                # the default generator of unix targets: linux, osx, ios, android, wasm
                if (!$cmake_generators) {
                    $cmake_generators = @{
                        'linux'   = 'Unix Makefiles'
                        'android' = 'Ninja'
                        'wasm'    = 'Ninja'
                        'osx'     = 'Xcode'
                        'ios'     = 'Xcode'
                        'tvos'    = 'Xcode'
                        'watchos' = 'Xcode'
                    }
                }
                $cmake_generator = $cmake_generators[$TARGET_OS]
                if ($null -eq $cmake_generator) {
                    $cmake_generator = if (!$IsWin) { 'Unix Makefiles' } else { 'Ninja' }
                }
            }

            if ($cmake_generator) {
                $using_ninja = $cmake_generator.StartsWith('Ninja')

                if (!$is_wasm) {
                    $CONFIG_ALL_OPTIONS += '-G', $cmake_generator
                }

                if ($cmake_generator -eq 'Unix Makefiles' -or $using_ninja) {
                    $CONFIG_ALL_OPTIONS += "-DCMAKE_BUILD_TYPE=$optimize_flag"
                }

                if ($using_ninja -and $Global:is_android) {
                    $CONFIG_ALL_OPTIONS += "-DCMAKE_MAKE_PROGRAM=$ninja_prog"
                }
            }

            $INST_DIR = $null
            $xopts_hints = 2
            $xopt_presets = 0
            $xprefix_optname = '-DCMAKE_INSTALL_PREFIX='
            $xopts = [array]$options.xc
            foreach ($opt in $xopts) {
                if ($opt.StartsWith('-B')) {
                    $BUILD_DIR = $opt.Substring(2).Trim()
                    ++$xopt_presets
                }
                elseif ($opt.StartsWith($xprefix_optname)) {
                    ++$xopt_presets
                    $INST_DIR = $opt.SubString($xprefix_optname.Length)
                }
                if ($xopt_presets -eq $xopts_hints) {
                    break
                }
            }
            
            if (!$BUILD_DIR) {
                $BUILD_DIR = resolve_out_dir $cmake_build_prefix 'build'
            }
            if (!$INST_DIR) {
                $INST_DIR = resolve_out_dir $cmake_install_prefix 'install'
                $CONFIG_ALL_OPTIONS += "-DCMAKE_INSTALL_PREFIX=$INST_DIR"
            }
        }
        else {
            # android gradle
            # replace all cmake config options -DXXX to -P_1K_XXX
            $xopts = @()
            foreach ($opt in $options.xc) {
                if ($opt.startsWith('-D')) {
                    $xopts += "-P_1K_$($opt.substring(2))"
                }
                elseif ($opt.startsWith('-P')) {
                    $xopts += $opt
                } # ignore unknown option type
            }
        }

        # step2. apply additional cross make options
        if ($xopts.Count -gt 0) {
            $b1k.println("Apply additional cross make options: $($xopts), Count={0}" -f $xopts.Count)
            $CONFIG_ALL_OPTIONS += $xopts
        }

        $b1k.println("CONFIG_ALL_OPTIONS=$CONFIG_ALL_OPTIONS, Count={0}" -f $CONFIG_ALL_OPTIONS.Count)

        if ($Global:is_android -and $is_gradlew) {
            $storedLocation = (Get-Location).Path
            $build_tool = (Get-Command $options.xt).Source
            $build_tool_dir = Split-Path $build_tool -Parent
            Set-Location $build_tool_dir
            if (!$configOnly) {
                if ($optimize_flag -eq 'Debug') {
                    & $build_tool assembleDebug $CONFIG_ALL_OPTIONS | Out-Host
                }
                else {
                    & $build_tool assembleRelease $CONFIG_ALL_OPTIONS | Out-Host
                }
            }
            else {
                & $build_tool tasks
            }
            Set-Location $storedLocation
        }
        else {
            # step3. configure

            $workDir = $(Get-Location).Path

            $mainDep = Join-Path $workDir 'CMakeLists.txt'
            if (!$b1k.isfile($mainDep)) {
                $b1k.println("Missing CMakeLists.txt in $workDir")
                Set-Location $stored_cwd
                return
            }

            $mainDepChanged = $false
            # A Windows file time is a 64-bit value that represents the number of 100-nanosecond
            $tempFileItem = Get-Item $mainDep
            $lastWriteTime = $tempFileItem.LastWriteTime.ToFileTimeUTC()
            $tempFile = Join-Path $BUILD_DIR 'b1k_cache.txt'

            $storeHash = 0
            if ($b1k.isfile($tempFile)) {
                $storeHash = Get-Content $tempFile -Raw
            }
            $hashValue = $b1k.hash("$CONFIG_ALL_OPTIONS#$lastWriteTime")
            $mainDepChanged = "$storeHash" -ne "$hashValue"
            $cmakeCachePath = $b1k.realpath("$BUILD_DIR/CMakeCache.txt")

            if ($mainDepChanged -or !$b1k.isfile($cmakeCachePath) -or $forceConfig) {
                if (!$is_wasm) {
                    cmake -B $BUILD_DIR $CONFIG_ALL_OPTIONS | Out-Host
                }
                else {
                    emcmake cmake -B $BUILD_DIR $CONFIG_ALL_OPTIONS | Out-Host
                }
                Set-Content $tempFile $hashValue -NoNewline
            }

            if (!$configOnly) {
                if (!$is_engine) {
                    if (!$b1k.isfile($cmakeCachePath)) {
                        throw "The cmake generate incomplete, pelase add '-f' to re-generate again"
                    }
                }

                # step4. build
                # apply additional build options
                $BUILD_ALL_OPTIONS += "--parallel"
                if ($Global:is_linux) {
                    $BUILD_ALL_OPTIONS += "$(nproc)"
                }
                if (($cmake_generator -eq 'Xcode') -and ($BUILD_ALL_OPTIONS.IndexOf('--verbose') -eq -1)) {
                    $BUILD_ALL_OPTIONS += '--', '-quiet'
                }
                $b1k.println("BUILD_ALL_OPTIONS=$BUILD_ALL_OPTIONS, Count={0}" -f $BUILD_ALL_OPTIONS.Count)

                cmake --build $BUILD_DIR $BUILD_ALL_OPTIONS | Out-Host
            }
        }
    } else {
        # google gclient/gn build system
        # refer: https://chromium.googlesource.com/chromium/src/+/eca97f87e275a7c9c5b7f13a65ff8635f0821d46/tools/gn/docs/reference.md#args_specifies-build-arguments-overrides-examples
        
        $stored_env_path = $null
        $gn_buildargs_overrides = @()
        
        if ($Global:is_winrt) {
            $gn_buildargs_overrides += 'target_os=\"winuwp\"'
        } elseif($Global:is_ios) {
            $gn_buildargs_overrides += 'target_os=\"ios\"'
            if ($TARGET_CPU -eq 'x64') {
                $gn_buildargs_overrides += 'target_environment=\"simulator\"'
            }
        } elseif($Global:is_android) {
            $gn_buildargs_overrides += 'target_os=\"android\"'
            $stored_env_path = $env:PATH
            active_ndk_toolchain
        }
        $gn_target_cpu = if ($TARGET_CPU -ne 'armv7') { $TARGET_CPU } else { 'arm' }
        $gn_buildargs_overrides += "target_cpu=\`"$gn_target_cpu\`""

        if ($options.xc) {
            $gn_buildargs_overrides += $options.xc
        }

        if ($Global:is_darwin_embed_device) {
            $gn_buildargs_overrides += 'ios_enable_code_signing=false'
        }

        Write-Output ("gn_buildargs_overrides=$gn_buildargs_overrides, Count={0}" -f $gn_buildargs_overrides.Count)
        
        $BUILD_DIR = resolve_out_dir $null 'build'
        $gn_gen_args = @('gen', $BUILD_DIR)
        if ($Global:is_win_family) {
            $gn_gen_args += '--ide=vs2022','--sln=angle-release'
        }

        if ($gn_buildargs_overrides) {
            $gn_gen_args += "--args=`"$gn_buildargs_overrides`""
        }

        Write-Output "Executing command: {gn $gn_gen_args}"

        # Note:
        #  1. powershell 7.2.12 works: gn $gn_gen_args, but 7.4.0 not works
        #  2. only --args="target_cpu=\"x64\"" works
        #  3. --args='target_cpu="x64" not work invoke from pwsh
        if($IsWin) {
            cmd /c "gn $gn_gen_args"
        }
        else {
            if ([VersionEx]$pwsh_ver -ge [VersionEx]'7.3') {
                bash -c "gn $gn_gen_args"
            } else {
                gn $gn_gen_args
            }
        }

        # build
        autoninja -C $BUILD_DIR --verbose $options.t

        # restore env:PATH
        if ($stored_env_path) {
            $env:PATH = $stored_env_path
        }
    }

    $Global:BUILD_DIR = $BUILD_DIR

    $env:buildResult = ConvertTo-Json @{
        buildDir     = $BUILD_DIR
        targetOS     = $TARGET_OS
        hostArch     = $hostArch
        isHostArch   = $TARGET_CPU -eq $hostArch
        isHostTarget = $is_host_target
        compilerID   = $TOOLCHAIN_NAME
    }

    Set-Location $stored_cwd
}

