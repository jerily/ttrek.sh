# ttrek 1.3.0 saves space with shared source files

**ttrek 1.3.0 is here!** Packages that build from the same source archive can
now share one unpacked copy. That means less disk space spent storing the same
code over and over.

Imagine several people building different models from one big instruction
book. Each person needs their own worktable, but they can all read the same
book. Making a full photocopy for every person just takes up more room.

That is the idea behind a **shared source directory**: one folder containing
the original code, with separate folders where each package does its building.

The AWS SDK for C++ is a good example. Packages for services such as DynamoDB,
S3, KMS, and SES all use the same large SDK archive. Previously, each service
recipe unpacked its own full copy. The updated recipes let those services
reuse one shared SDK copy within your project.

Each service still has its own build folder and logs. The shared files stay
inside your project's [ttrek-venv directory](/docs/ttrek-venv), under
`build/shared-source`, and are marked read-only to prevent accidental changes.
ttrek checks the archive's fingerprint before choosing a cached copy, and
only reuses an extraction that finished successfully.

AWS core still keeps a private copy because it adds extra supporting files.
The saving comes from removing the need for another full SDK copy for every
service. Sharing is a choice made by each package recipe; existing recipes
continue to work as before.

Already have ttrek? Update it and check your version:

```sh
ttrek self-update
ttrek version
```

When installing packages, there is also a useful flag for troubleshooting:
**`-fail-verbose`**.

```sh
ttrek install -fail-verbose aws-sdk-cpp-dynamodb aws-sdk-cpp-s3
```

If a build step fails, this prints that step's log directly in your terminal,
including the compiler's error messages when compilation fails. You can see
what went wrong without opening a separate log file. Successful builds keep
their usual concise output.

If those services are already installed, add `-force` to rebuild them with
the updated recipes. Updating ttrek alone does not rebuild existing packages.
If you use a local registry copy, make sure its recipes are up to date too.

New to ttrek? Follow [Getting started](/docs/getting-started) to install it and
the build tools.
