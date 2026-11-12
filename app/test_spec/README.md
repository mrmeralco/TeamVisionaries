# Flutter spec tests (Aldrin + Shane)

These tests describe what the app's service layer must do. They read the **same contract** as the
backend tests (`docs/contracts/schema.json` + `examples/`), so when they pass, the app and the server agree.

## Use them

After `flutter create --org ph.solaris --project-name solaris .` in `app/`:

```bash
flutter pub add http web_socket_channel
```

```bash
mkdir -p test/spec && cp test_spec/*.dart test/spec/
```

```bash
flutter test test/spec
```

They import `package:solaris/services/api_service.dart` and `package:solaris/services/mock_api_service.dart`.
If you don't have those yet, start from the reference (it passes all 30 tests):

```bash
mkdir -p lib/services && cp test_spec/reference/*.dart lib/services/
```

Mock assets for `MockApiService`: copy `../docs/contracts/examples/*.json` to `assets/mock/` and add
`assets/mock/` under `flutter: assets:` in `pubspec.yaml`.

## What they check

| Group | Means |
|---|---|
| contract examples | The shared example files are valid (sanity check of the checker) |
| ApiService | Each method hits the right **method + path + body** (`POST /api/chat {"message": ...}`, `PUT /api/settings` partial, ...), returns contract-shaped data, decodes ₱ as UTF-8, throws on 4xx/5xx, builds `ws://<ip>:8000/ws/live` |
| MockApiService | Same methods with no server, implements `ApiService` (so one flag switches them), live stream emits `/ws/live`-style messages |

Your methods can return `Map<String, dynamic>` or your own model classes. Models just need a `toJson()`
that returns the contract shape; the tests call it.

## What tests can't check: do this by eye

The screen-level checklist (offline, brownout, fault, empty states, live updates) is in
[TESTING.md](../../TESTING.md#flutter-screens-by-eye).
