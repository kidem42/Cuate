package android.content
open class Context {
    val applicationContext get() = this
    fun getString(id: Int, vararg args: Any): String = "budget"
    fun getSharedPreferences(name: String, mode: Int) = SharedPreferences()
    companion object { const val MODE_PRIVATE = 0 }
}
class SharedPreferences {
    private val values = mutableMapOf<String, Any>()
    fun getInt(key: String, default: Int) = values[key] as? Int ?: default
    fun getFloat(key: String, default: Float) = values[key] as? Float ?: default
    fun getBoolean(key: String, default: Boolean) = values[key] as? Boolean ?: default
    fun edit() = Editor()
    inner class Editor {
        fun putInt(key: String, value: Int) = apply { values[key] = value }
        fun putFloat(key: String, value: Float) = apply { values[key] = value }
        fun putBoolean(key: String, value: Boolean) = apply { values[key] = value }
        fun apply() {}
    }
}
