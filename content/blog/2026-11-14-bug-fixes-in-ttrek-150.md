# ttrek 1.5.0: fewer build surprises

![A friendly bug with a small bandage on its shell.](images/ttrek-150-bug-fixes.png)

**ttrek 1.5.0 focuses on the little things that get in your way:** failed builds,
unhelpful errors, and unnecessary changes to your project files.

- **CMake builds work with Snap.** A fix for redirected output prevents build
  failures that could leave empty logs. No `PATH` changes needed.
- **Missing Autoconf gets a clear explanation.** When a recipe needs it, ttrek
  checks early and tells you how to install it. Other recipes carry on as usual.
- **Your dependency order stays yours.** Installs and updates preserve the order
  of existing dependencies in `ttrek.json`, keeping diffs easier to read.

Small fixes. Smoother builds.

Update ttrek and check your version:

```sh
ttrek self-update
ttrek version
```

New here? [Get started with ttrek](/docs/getting-started).
