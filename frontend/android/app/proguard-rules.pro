# Keep generic signatures; needed for correct type resolution
-keepattributes Signature

# Keep Gson TypeToken and its subclasses (prevents "Missing type parameter")
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken

# (Optional) Be extra safe with Gson
-keep class com.google.gson.** { *; }
-keep class com.google.gson.stream.** { *; }

# Keep the plugin’s receivers/classes from being over-optimised
-keep class com.dexterous.flutterlocalnotifications.** { *; }
