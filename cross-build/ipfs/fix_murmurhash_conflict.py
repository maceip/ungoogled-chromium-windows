# Fix MurmurHash3 duplicate symbol conflict between ipfs_client and Chromium's smhasher
import re

# 1. Remove MurmurHash3.cc from ipfs_client BUILD.gn sources
p = '/build/chromium/src/third_party/ipfs_client/BUILD.gn'
t = open(p).read()
t = t.replace('       "src/smhasher/MurmurHash3.cc", \n', '')
t = t.replace('       "src/smhasher/MurmurHash3.cc",\n', '')

# 2. Add //third_party/smhasher:murmurhash3 to deps
old_deps = '      deps = [\n        "//third_party/abseil-cpp:absl",\n        "//base",\n      ]'
new_deps = '      deps = [\n        "//third_party/abseil-cpp:absl",\n        "//base",\n        "//third_party/smhasher:murmurhash3",\n      ]'
t = t.replace(old_deps, new_deps)

open(p, 'w').write(t)
print('Updated ipfs_client BUILD.gn')

# 3. Update smhasher BUILD.gn visibility to allow ipfs_client
p2 = '/build/chromium/src/third_party/smhasher/BUILD.gn'
t2 = open(p2).read()
old_vis = '    "//third_party/nearby:connections_implementation_mediums",\n  ]'
new_vis = '    "//third_party/nearby:connections_implementation_mediums",\n    "//third_party/ipfs_client:*",\n  ]'
t2 = t2.replace(old_vis, new_vis)
open(p2, 'w').write(t2)
print('Updated smhasher visibility')

# 4. Check include path - ipfs_client uses #include <smhasher/MurmurHash3.h>
# Chromium's header is at third_party/smhasher/src/src/MurmurHash3.h
# ipfs_client's was at third_party/ipfs_client/include/smhasher/MurmurHash3.h
# The include/smhasher/MurmurHash3.h should still be there for the header declaration
# Let's verify it's compatible
import os
if os.path.exists('/build/chromium/src/third_party/ipfs_client/include/smhasher/MurmurHash3.h'):
    print('ipfs_client header still exists - include path OK')
else:
    print('WARNING: ipfs_client smhasher header missing!')
