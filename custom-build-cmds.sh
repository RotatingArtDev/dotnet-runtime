docker run \
-v `pwd`:/runtime \
-w /runtime \
mcr.microsoft.com/dotnet-buildtools/prereqs:azurelinux-3.0-net10.0-cross-android-openssl-amd64 \
tail -f /dev/null

docker exec -it bold_hodgkin ./build.sh clr.runtime+clr.alljits+clr.corelib+clr.nativecorelib+clr.tools+clr.crossarchtools+clr.packages+libs+host+packs -rf coreclr -arch arm64 -os linux-bionic -c Release -restore -build -publish
