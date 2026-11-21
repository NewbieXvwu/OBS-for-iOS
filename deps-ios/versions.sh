# Sources without submodules use versioned upstream archives.
version_simde=0.8.2
version_uthash=2.3.0
version_jansson=2.14.1
version_x264=20191217-2245-stable
version_x265=3.6
version_mbedtls=3.6.4
version_speexdsp=1.2.1
version_rnnoise=0.2
version_freetype=2.13.3
version_curl=8.15.0
version_srt=1.5.4
version_librist=0.2.11
version_libdatachannel=0.24.2
version_asio=1.30.2
version_websocketpp=0.8.2
version_json=3.11.3
version_ffmpeg=8.0.3

github_archive() {
  printf 'https://codeload.github.com/%s/tar.gz/refs/tags/%s\n' "$1" "$2"
}

dep_url() {
  case "$1" in
    simde) github_archive simd-everywhere/simde "v$2" ;;
    uthash) github_archive troydhanson/uthash "v$2" ;;
    jansson) github_archive akheron/jansson "v$2" ;;
    x264) printf 'https://download.videolan.org/pub/videolan/x264/snapshots/x264-snapshot-%s.tar.bz2\n' "$2" ;;
    x265) printf 'https://github.com/Multicorewareinc/x265/releases/download/%s/x265_%s.tar.gz\n' "$2" "$2" ;;
    mbedtls) printf 'https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-%s/mbedtls-%s.tar.bz2\n' "$2" "$2" ;;
    speexdsp) printf 'https://downloads.xiph.org/releases/speex/speexdsp-%s.tar.gz\n' "$2" ;;
    rnnoise) printf 'https://github.com/xiph/rnnoise/releases/download/v%s/rnnoise-%s.tar.gz\n' "$2" "$2" ;;
    freetype) github_archive freetype/freetype "VER-${2//./-}" ;;
    curl) github_archive curl/curl "curl-${2//./_}" ;;
    srt) github_archive Haivision/srt "v$2" ;;
    librist) printf 'https://code.videolan.org/rist/librist/-/archive/v%s/librist-v%s.tar.gz\n' "$2" "$2" ;;
    asio) github_archive chriskohlhoff/asio "asio-${2//./-}" ;;
    websocketpp) github_archive zaphoyd/websocketpp "$2" ;;
    json) github_archive nlohmann/json "v$2" ;;
    ffmpeg) printf 'https://ffmpeg.org/releases/ffmpeg-%s.tar.xz\n' "$2" ;;
  esac
}
