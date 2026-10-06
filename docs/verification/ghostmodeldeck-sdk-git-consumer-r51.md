# Official fixed Git SDK consumer preflight — r51

Observed 2026-10-06, host Dart 3.13.5 / Flutter 3.47.6. This is **#18 prerequisite preparation**, not production integration or #18 completion. The #15 writer retained exclusive runtime/Council/catalog/tests and SERIAL container slot throughout.

## Actual execution

An independent ignored consumer under `.tooling/sdk-git-consumer-r51/` used its own `PUB_CACHE` and this exact official dependency, rather than the earlier temporary PATH dependency:

```yaml
maclauncher_sdk:
  git:
    url: https://github.com/Ghost233/MacLauncher.git
    ref: bc7262f4047e81f55922c203948ac64d9e0e2d13
    path: packages/maclauncher_sdk
```

Normal **online** `dart pub get` exited 0; no offline/no-pub flags, package workspace rewrite or source checkout substitution. The generated lockfile records source `git`, package `0.1.0`, and both requested/resolved refs equal the fixed commit. An independent validator verified the actual checkout HEAD, package-config path containment in the separate cache, and byte equality of the SDK pubspec/export/client/protocol files against the unchanged fixed archive used in r44. Root application dependencies remained unchanged versus HEAD.

Host formatter exited 0, `dart analyze smoke.dart` exited 0 with **No issues found!**, and `dart run smoke.dart` exited 0. The probe only constructed public callback/DTO objects and took the `MacLauncherSdk.connect` method tearoff; it **never called connect or any business callback**.

Deterministic assertions confirmed:

- Protocol version 1; non-null compile-only callbacks declare `start/recycle/status/logs` and `openWindow`, with no `onSetEntryManaged` declaration.
- Unknown status retains null instance/ready/observed time/message, not a fabricated stopped/failed snapshot.
- Unknown log timestamp/stream and batch identity/observation remain unknown.
- Log query default 200 and decoded maximum 500.

The frozen [JSON proof](ghostmodeldeck-sdk-git-consumer-r51.json) includes raw record SHA256/byte counts, exact checkout identity, four SDK source hashes and smoke DTOs. Raw logs/exit files remain under the ignored consumer; they are not application container gates.

## Scope limits

This establishes external **fixed Git subpath/ref** resolution and public SDK consumer feasibility, improving on r44 PATH-only evidence. It does not establish production root Flutter dependencies/lockfile, isolated container build, native socket handshake, explicit project association, reconnect/conflict/dedup, service lifecycle, logs from real processes, native open/close/window behavior or application exit. No launcher bindings, original SDK/source repositories, user settings, model resources or native services were modified or connected. Compile-only callbacks are not a claim of actual application capabilities.

Future #18 must ship the official fixed Git dependency in the real application, run normal online container gates, and prove actual socket/business/window behavior under the specification's single `inference` service identity. No issue is closed by this preflight.
