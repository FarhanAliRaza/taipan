# /// script
# dependencies = ["markupsafe"]
# ///
import markupsafe
from markupsafe import escape

# Prove the C speedups extension (.so) loaded, not the pure-python fallback.
import markupsafe._speedups  # noqa: F401

print("markupsafe loaded WITH C extension:", escape("<taipan & friends>"))
