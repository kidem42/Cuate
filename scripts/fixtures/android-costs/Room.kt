package androidx.room
import kotlinx.coroutines.sync.withLock
annotation class Entity(val tableName: String, val indices: Array<Index>)
annotation class Index(val value: String)
annotation class PrimaryKey
annotation class ColumnInfo(val defaultValue: String)
annotation class Dao
annotation class Query(val value: String)
annotation class Insert(val onConflict: Int)
object OnConflictStrategy { const val IGNORE = 1 }

suspend fun <T> com.aispotlight.android.data.AppDatabase.withTransaction(block: suspend () -> T): T = mutex.withLock { block() }
