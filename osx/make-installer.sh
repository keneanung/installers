#!/bin/bash

# abort script if any command fails
set -e
shopt -s expand_aliases

# extract program name for message
pgm=$(basename "$0")

release=""
ptb=""

BUILD_DIR="source/build"
SOURCE_DIR="source"

# shellcheck disable=SC2154
# If run via Github Actions, use Qt5_DIR for the custom Qt location - otherwise assume system default
[ -n "$Qt5_DIR" ] && QT_DIR="${Qt5_DIR}" || QT_DIR="/usr/local/opt/qt/bin"

if [ -n "$GITHUB_REPOSITORY" ] ; then
  BUILD_DIR=$BUILD_FOLDER
  SOURCE_DIR=$GITHUB_WORKSPACE
fi

# find out if we do a release or ptb build
while getopts ":pr:" option; do
  if [ "${option}" = "r" ]; then
    release="${OPTARG}"
    shift $((OPTIND-1))
  elif [ "${option}" = "p" ]; then
    ptb="yep"
    shift $((OPTIND-1))
  else
    echo "Unknown option -${option}"
    exit 1
  fi
done

# set path to find macdeployqt
PATH=/usr/local/opt/qt/bin:$PATH

cd "${BUILD_DIR}"

# get the app to package
app=$(basename "${1}")

if [ -z "$app" ]; then
  echo "No Mudlet app folder to package given."
  echo "Usage: $pgm <Mudlet app folder to package>"
  exit 2
fi
app=$(find . -iname "${app}" -type d)
if [ -z "${app}" ]; then
  echo "error: couldn't determine location of the ./app folder"
  exit 1
fi

echo "Deploying ${app}"

# install installer dependencies, except on Github where they're preinstalled at this point
if [ -z "$GITHUB_REPOSITORY" ]; then
  echo "Running brew update-reset"
  brew update-reset
  echo "Finished with brew update-reset"
  BREWS="sqlite3 lua lua@5.1 node luarocks"
  for i in $BREWS; do
    echo "Checking if $i needs an upgrade..."
    brew outdated | grep -q "$i" && brew upgrade "$i"
  done
  for i in $BREWS; do
    echo "Checking if $i needs an install..."
    brew list --formulae | grep -q "$i" || brew install "$i"
  done

  alias luarocks-5.1="luarocks --lua-dir='$(brew --prefix lua@5.1)'"
  luarocks-5.1 --local install LuaFileSystem
  luarocks-5.1 --local install lrexlib-pcre
  luarocks-5.1 --local install LuaSQL-SQLite3 SQLITE_DIR=/usr/local/opt/sqlite
  # Although it is called luautf8 here it builds a file called lua-utf8.so:
  luarocks-5.1 --local install luautf8
  luarocks-5.1 --local install lua-yajl
  # This is the Brimworks one (same as lua-yajl) note the hyphen, the one without
  # is the Kelper project one which has the, recently (2020), troublesome
  # dependency on zziplib (libzzip), however to avoid clashes in the field
  # it installs itself in brimworks subdirectory which must be accomodated
  # in where we put it and how we "require" it:
  luarocks-5.1 --local install lua-zip
fi

# create an alias to avoid the need to list the lua dir all the time
# we want to expand the subshell only once (it's only temporary anyways)
# shellcheck disable=2139
if [ ! -f "macdeployqtfix.py" ]; then
  wget https://raw.githubusercontent.com/aurelien-rainone/macdeployqtfix/master/macdeployqtfix.py
fi

# Ensure Homebrew's npm is used, instead of an outdated one
PATH=/usr/local/bin:$PATH
# Add node path, as node seems to error when it's missing
mkdir -p "$HOME"/.npm-global/lib
npm install -g appdmg

# copy in 3rd party framework first so there is the chance of things getting fixed if it doesn't exist
if [ ! -d "${app}/Contents/Frameworks/Sparkle.framework" ]; then
  mkdir -p "${app}/Contents/Frameworks/Sparkle.framework"
  cp -R "${SOURCE_DIR}/3rdparty/cocoapods/Pods/Sparkle/Sparkle.framework" "${app}/Contents/Frameworks"
fi

# Bundle in Qt libraries
echo "Running macdeployqt..."
macdeployqt "${app}"

# fix unfinished deployment of macdeployqt
echo "Running macdeployqtfix..."
python macdeployqtfix.py "${app}/Contents/MacOS/Mudlet" "${QT_DIR}"

# Bundle in dynamically loaded libraries
cp "${HOME}/.luarocks/lib/lua/5.1/lfs.so" "${app}/Contents/MacOS"

cp "${HOME}/.luarocks/lib/lua/5.1/rex_pcre.so" "${app}/Contents/MacOS"
# rex_pcre has to be adjusted to load libpcre from the same location
python macdeployqtfix.py "${app}/Contents/MacOS/rex_pcre.so" "${QT_DIR}"

cp -r "${HOME}/.luarocks/lib/lua/5.1/luasql" "${app}/Contents/MacOS"
cp /usr/local/opt/sqlite/lib/libsqlite3.0.dylib  "${app}/Contents/Frameworks/"
# sqlite3 has to be adjusted to load libsqlite from the same location
python macdeployqtfix.py "${app}/Contents/Frameworks/libsqlite3.0.dylib" "${QT_DIR}"
# need to adjust sqlite3.lua manually as it is a level lower than expected...
install_name_tool -change "/usr/local/opt/sqlite/lib/libsqlite3.0.dylib" "@executable_path/../../Frameworks/libsqlite3.0.dylib" "${app}/Contents/MacOS/luasql/sqlite3.so"

cp "${HOME}/.luarocks/lib/lua/5.1/lua-utf8.so" "${app}/Contents/MacOS"

# The lua-zip rock:
# Also need to adjust the zip.so manually so that it can be at a level down from
# the executable:
mkdir "${app}/Contents/MacOS/brimworks"
cp "${HOME}/.luarocks/lib/lua/5.1/brimworks/zip.so" "${app}/Contents/MacOS/brimworks"
# Special case - libzip.5.dylib in Github Actions is located in this path
if [ -n "$GITHUB_REPOSITORY" ] ; then
  mkdir -p "/usr/local/lib/libzip.5.dylib.framework"
  cp "/usr/local/lib/libzip.5.dylib" "/usr/local/lib/libzip.5.dylib.framework/libzip.5.dylib"
fi
python macdeployqtfix.py "${app}/Contents/MacOS/brimworks/zip.so" "/usr/local"

cp "${SOURCE_DIR}/3rdparty/discord/rpc/lib/libdiscord-rpc.dylib" "${app}/Contents/Frameworks"

if [ -d "${SOURCE_DIR}/3rdparty/lua_code_formatter" ]; then
  # we renamed lcf at some point
  LCF_NAME="lua_code_formatter"
else
  LCF_NAME="lcf"
fi
cp -r "${SOURCE_DIR}/3rdparty/${LCF_NAME}" "${app}/Contents/MacOS"
if [ "${LCF_NAME}" != "lcf" ]; then
  mv "${app}/Contents/MacOS/${LCF_NAME}" "${app}/Contents/MacOS/lcf"
fi

cp "${HOME}/.luarocks/lib/lua/5.1/yajl.so" "${app}/Contents/MacOS"
# yajl has to be adjusted to load libyajl from the same location
python macdeployqtfix.py "${app}/Contents/MacOS/yajl.so" "${QT_DIR}"
if [ -n "$GITHUB_REPOSITORY" ] ; then
  cp "/Users/runner/work/Mudlet/Mudlet/3rdparty/vcpkg/packages/yajl_x64-osx/lib/libyajl.2.dylib" "${app}/Contents/Frameworks/libyajl.2.dylib"
  install_name_tool -change "/Users/runner/work/Mudlet/Mudlet/3rdparty/vcpkg/packages/yajl_x64-osx/lib/libyajl.2.dylib" "@executable_path/../Frameworks/libyajl.2.dylib" "${app}/Contents/MacOS/yajl.so"
fi

# Edit some nice plist entries, don't fail if entries already exist
if [ -z "${ptb}" ]; then
  /usr/libexec/PlistBuddy -c "Add CFBundleName string Mudlet" "${app}/Contents/Info.plist" || true
  /usr/libexec/PlistBuddy -c "Add CFBundleDisplayName string Mudlet" "${app}/Contents/Info.plist" || true
else
  /usr/libexec/PlistBuddy -c "Add CFBundleName string Mudlet PTB" "${app}/Contents/Info.plist" || true
  /usr/libexec/PlistBuddy -c "Add CFBundleDisplayName string Mudlet PTB" "${app}/Contents/Info.plist" || true
fi

if [ -z "${release}" ]; then
  stripped="${app#Mudlet-}"
  version="${stripped%.app}"
  shortVersion="${version%%-*}"
else
  version="${release}"
  shortVersion="${release}"
fi

/usr/libexec/PlistBuddy -c "Add CFBundleShortVersionString string ${shortVersion}" "${app}/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Add CFBundleVersion string ${version}" "${app}/Contents/Info.plist" || true

# Sparkle settings, see https://sparkle-project.org/documentation/customization/#infoplist-settings
if [ -z "${ptb}" ]; then
  /usr/libexec/PlistBuddy -c "Add SUFeedURL string https://feeds.dblsqd.com/MKMMR7HNSP65PquQQbiDIw/release/mac/x86_64/appcast" "${app}/Contents/Info.plist" || true
else
  /usr/libexec/PlistBuddy -c "Add SUFeedURL string https://feeds.dblsqd.com/MKMMR7HNSP65PquQQbiDIw/public-test-build/mac/x86_64/appcast" "${app}/Contents/Info.plist" || true
fi
/usr/libexec/PlistBuddy -c "Add SUEnableAutomaticChecks bool true" "${app}/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Add SUAllowsAutomaticUpdates bool true" "${app}/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Add SUAutomaticallyUpdate bool true" "${app}/Contents/Info.plist" || true

# Enable HiDPI support
/usr/libexec/PlistBuddy -c "Add NSPrincipalClass string NSApplication" "${app}/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Add NSHighResolutionCapable string true" "${app}/Contents/Info.plist" || true


# Sign everything now that we're done modifying contents of the .app file
# Keychain is already setup in travis.osx.after_success.sh for us
if [ -n "$IDENTITY" ] && security find-identity | grep -q "$IDENTITY"; then
  codesign --deep --force --sign "$IDENTITY" "${app}"
  echo "Validating codesigning worked with codesign -vv --deep-verify:"
  codesign -vv --deep-verify "${app}"
fi

# Generate final .dmg
cd ../../
rm -f ~/Desktop/[mM]udlet*.dmg

# Modify appdmg config file according to the app file to package
perl -pi -e "s|../source/build/.*Mudlet.*\\.app|${BUILD_DIR}/${app}|i" "${BUILD_DIR}/../installers/osx/appdmg/mudlet-appdmg.json"
# Update icons to the correct type
if [ -z "${ptb}" ]; then
  perl -pi -e "s|../source/src/icons/.*\\.icns|${SOURCE_DIR}/src/icons/mudlet_ptb.icns|i" "${BUILD_DIR}/../installers/osx/appdmg/mudlet-appdmg.json"
else
  if [ -z "${release}" ]; then
    perl -pi -e "s|../source/src/icons/.*\\.icns|${SOURCE_DIR}/src/icons/mudlet_dev.icns|i" "${BUILD_DIR}/../installers/osx/appdmg/mudlet-appdmg.json"
  else
    perl -pi -e "s|../source/src/icons/.*\\.icns|${SOURCE_DIR}/src/icons/mudlet.icns|i" "${BUILD_DIR}/../installers/osx/appdmg/mudlet-appdmg.json"
  fi
fi

# Last: build *.dmg file
appdmg "${BUILD_DIR}/../installers/osx/appdmg/mudlet-appdmg.json" "${HOME}/Desktop/$(basename "${app%.*}").dmg"
