# OkHttp platform warnings
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# PdfBox-Android references an optional JPEG2000 decoder (JPX images in
# PDFs) that is not bundled; R8 must not fail on the missing class. Such
# images are simply skipped by the text extraction.
-dontwarn com.gemalto.jp2.**
