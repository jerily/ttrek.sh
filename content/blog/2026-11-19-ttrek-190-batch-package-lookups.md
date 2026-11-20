# ttrek 1.9.0 looks up packages in batches

![A trolley carries a stack of parcels toward an open catalog drawer.](images/ttrek-190-batch-lookups.jpg)

When you run `ttrek install`, ttrek 1.9.0 can ask a registry for the available
versions of several packages in one request. Once it resolves your
dependencies, it can fetch their build recipes in batches too.

For projects with several dependencies, that means fewer network round trips
and less time waiting for the registry before the build starts. Batching is
automatic on registries that support it.
