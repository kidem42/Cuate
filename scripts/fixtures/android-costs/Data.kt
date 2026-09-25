package com.aispotlight.android.data
import android.content.Context
import com.aispotlight.android.core.LLMImage
import java.io.File
object ImageStore {
 fun file(context: Context, attachment: ChatAttachment) = File("/nonexistent")
 fun contentBase64(context: Context, attachment: ChatAttachment) = ""
 fun llmImage(context: Context, attachment: ChatAttachment): LLMImage? = null
}
object AppDatabase {
 fun get(context: Context) = this
 fun spendDao(): SpendDao = ledger
 val ledger = MemorySpendDao()
 val chats = MemoryChatDao()
 val mutex = kotlinx.coroutines.sync.Mutex()
}
class MemorySpendDao: SpendDao {
 val records = mutableListOf<SpendRecordEntity>()
 var failCount = 0
 var attempts = 0
 override suspend fun insert(record: SpendRecordEntity): Long {
  attempts++
  if (failCount-- > 0) error("fixture write failure")
  if (records.any { it.id == record.id }) return -1
  records.add(record); return records.size.toLong()
 }
 override suspend fun recordsBetween(from: Long, to: Long) = records.filter { it.timestamp >= from && it.timestamp < to }
 override suspend fun earliestTimestamp() = records.minOfOrNull { it.timestamp }
 override suspend fun costBetween(from: Long, to: Long) = recordsBetween(from,to).sumOf { it.costUSD ?: 0.0 }
}

class MemoryChatDao {
 var onPage: (() -> Unit)? = null
 suspend fun messagesBefore(id: String, before: String, limit: Int): List<ChatMessage> {
  val rows=messages[id].orEmpty()
  val index=rows.indexOfFirst { it.id==before }
  val result=if(index<0) emptyList() else rows.take(index).takeLast(limit).reversed()
  onPage?.invoke()
  return result
 }
 val conversations = mutableMapOf<String, Conversation>()
 val messages = mutableMapOf<String, List<ChatMessage>>()
 suspend fun conversation(id: String) = conversations[id]
 suspend fun allMessages(id: String) = messages[id].orEmpty()
 suspend fun setSummary(id: String, summary: String, count: Int) {
  conversations[id] = conversations[id]!!.copy(summary=summary,summaryCoversCount=count)
 }
}
