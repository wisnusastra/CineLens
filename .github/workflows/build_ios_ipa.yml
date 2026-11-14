name: Build CineLens iOS IPA

on:
  workflow_dispatch:
  push:
    branches:
      - main

jobs:
  build-ios:
    runs-on: macos-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          channel: 'stable'
          cache: true

      - name: Build & Kemas CineLens iOS IPA (Unsigned)
        run: |
          chmod +x build_ios.sh
          ./build_ios.sh

      - name: Upload CineLens iOS IPA Artifact
        uses: actions/upload-artifact@v4
        with:
          name: CineLens-iOS-IPA
          path: build/ios/ipa/CineLens_iOS.ipa
          if-no-files-found: error
