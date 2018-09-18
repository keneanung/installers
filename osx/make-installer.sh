#!/bin/bash

# abort script if any command fails
set -e
shopt -s expand_aliases

# extract program name for message
pgm=$(basename "$0")

release=""

# find out if we do a release build
while getopts ":r:" o; do
  if [ "${o}" = "r" ]; then
    release="${OPTARG}"
  else
    echo "Unknown option -${o}"
    exit 1
  fi
done
shift $((OPTIND-1))

# set path to find macdeployqt
PATH=/usr/local/opt/qt/bin:$PATH

cd source/build

# get the app to package
app=$(basename "${1}")

if [ -z "$app" ]; then
  echo "No Mudlet app folder to package given."
  echo "Usage: $pgm <Mudlet app folder to package>"
  exit 2
fi

# install installer dependencies
brew update
BREWS="sqlite3 lua@5.1 node wget luarocks"
for i in $BREWS; do
  brew outdated | grep -q "$i" && brew upgrade "$i"
done
for i in $BREWS; do
  brew list | grep -q "$i" || brew install "$i"
done
# create an alias to avoid the need to list the lua dir all the time
# we want to expand the subshell only once (it's only tmeporary anyways)
# shellcheck disable=2139
alias luarocks-5.1="luarocks --lua-dir='$(brew --prefix lua@5.1)'"
if [ ! -f "macdeployqtfix.py" ]; then
  wget https://raw.githubusercontent.com/aurelien-rainone/macdeployqtfix/master/macdeployqtfix.py
fi
luarocks-5.1 --local install LuaFileSystem
luarocks-5.1 --local install lrexlib-pcre
luarocks-5.1 --local install LuaSQL-SQLite3 SQLITE_DIR=/usr/local/opt/sqlite
luarocks-5.1 --local install luautf8
luarocks-5.1 --local install lua-yajl

npm install -g ArmorText/node-appdmg#feature/background-hack

# Bundle in Qt libraries
macdeployqt "${app}"

# fix unfinished deployment of macdeployqt
python macdeployqtfix.py "${app}/Contents/MacOS/Mudlet" "/usr/local/opt/qt/bin"

# Bundle in dynamically loaded libraries
cp "${HOME}/.luarocks/lib/lua/5.1/lfs.so" "${app}/Contents/MacOS"
cp "${HOME}/.luarocks/lib/lua/5.1/rex_pcre.so" "${app}/Contents/MacOS"
# rex_pcre has to be adjusted to load libcpre from the same location
python macdeployqtfix.py "${app}/Contents/MacOS/rex_pcre.so" "/usr/local/opt/qt/bin"
cp -r "${HOME}/.luarocks/lib/lua/5.1/luasql" "${app}/Contents/MacOS"
cp "${HOME}/.luarocks/lib/lua/5.1/lua-utf8.so" "${app}/Contents/MacOS"
if [ -d "../3rdparty/lua_code_formatter" ]; then
  # we renamed lcf at some point
  LCF_NAME="lua_code_formatter"
else
  LCF_NAME="lcf"
fi
cp -r "../3rdparty/${LCF_NAME}" "${app}/Contents/MacOS"
if [ "${LCF_NAME}" != "lcf" ]; then
  mv "${app}/Contents/MacOS/${LCF_NAME}" "${app}/Contents/MacOS/lcf"
fi
cp "${HOME}/.luarocks/lib/lua/5.1/yajl.so" "${app}/Contents/MacOS"

# generate binary translation files and bundle them in
lrelease ../src/mudlet.pro
cp "../translations/translated/*.qm" "${app}/Contents/Resources"

# Edit some nice plist entries, don't fail if entries already exist
/usr/libexec/PlistBuddy -c "Add CFBundleName string Mudlet" "${app}/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Add CFBundleDisplayName string Mudlet" "${app}/Contents/Info.plist" || true
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
/usr/libexec/PlistBuddy -c "Add SUFeedURL string https://feeds.dblsqd.com/MKMMR7HNSP65PquQQbiDIw/release/mac/x86_64/appcast" "${app}/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Add SUEnableAutomaticChecks bool true" "${app}/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Add SUAllowsAutomaticUpdates bool true" "${app}/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Add SUAutomaticallyUpdate bool true" "${app}/Contents/Info.plist" || true

# Sign everything now that we're done modifying contents of the .app file
# Keychain is already setup in travis.osx.after_success.sh for us
if [ -n "$IDENTITY" ] && security find-identity | grep -q "$IDENTITY"; then
  codesign --deep -s "$IDENTITY" "${app}/Contents/Frameworks/Sparkle.framework/Resources/Autoupdate.app/"
  codesign --deep -s "$IDENTITY" "${app}"
fi

# Generate final .dmg
cd ../..
rm -f ~/Desktop/Mudlet*.dmg

# Modify appdmg config file according to the app file to package
perl -pi -e "s/Mudlet.*\\.app/${app}/" appdmg/mudlet-appdmg.json

# Last: build *.dmg file
appdmg appdmg/mudlet-appdmg.json "${HOME}/Desktop/${app%.*}.dmg"
