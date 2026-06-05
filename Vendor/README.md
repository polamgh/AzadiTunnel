# Vendor

`PsiphonTunnelCore.xcframework` is **not** committed (see root `.gitignore`). It is built from the pinned psiphon-tunnel-core revision:

```bash
bash Tooling/psiphon/build-ios-xcframework.sh
```

**Xcode Cloud** builds it automatically via `ci_scripts/ci_post_clone.sh` and `ci_scripts/ci_pre_xcodebuild.sh` (both call `ci_scripts/build-psiphon-vendor.sh`).
