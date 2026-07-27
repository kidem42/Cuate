package com.aispotlight.android.data

import android.content.Context
import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import kotlinx.coroutines.flow.Flow

/**
 * SQLite schema for chat history — the Android analog of the SwiftData models
 * in `ChatPersistence.swift` (SDConversation/SDMessage), adapted to the mobile
 * many-conversations model.
 */

@Entity(tableName = "conversations")
data class ConversationEntity(
    @PrimaryKey val id: String,
    val title: String,
    /** Preset the conversation was started with (drives the system prompt). */
    val presetName: String?,
    val createdAt: Long,
    val updatedAt: Long,
    /** Rolling summary of older turns (context compression). */
    val summary: String?,
    /** How many leading messages of the conversation the summary covers. */
    val summaryCoversCount: Int,
    /**
     * Non-null = this conversation mirrors a Hermes Agent gateway session
     * with that id; sends route through HermesChatService and history syncs
     * from the gateway transcript.
     */
    @ColumnInfo(defaultValue = "NULL") val hermesSessionId: String? = null,
    /**
     * Watermark of the gateway transcript (max row id already reflected
     * locally — by our own turn or an import). The mirror sync only imports
     * rows above it, so our own turns never come back as duplicates.
     */
    @ColumnInfo(defaultValue = "0") val hermesSyncedSeq: Int = 0,
)

@Entity(
    tableName = "messages",
    foreignKeys = [ForeignKey(
        entity = ConversationEntity::class,
        parentColumns = ["id"],
        childColumns = ["conversationId"],
        onDelete = ForeignKey.CASCADE,
    )],
    indices = [Index("conversationId"), Index("timestamp")],
)
data class MessageEntity(
    @PrimaryKey val id: String,
    val conversationId: String,
    val text: String,
    val isUser: Boolean,
    val timestamp: Long,
    /** "text" | "voice" | "system" */
    val messageType: String,
    /** Relative path of a voice recording, when messageType == "voice". */
    val audioPath: String?,
    /**
     * Compact digest of the web-search results an assistant reply was based on.
     * Re-attached to the API context for the most recent reply that has one.
     */
    val toolContext: String?,
    /** Whether the reply hit an error mid-stream (rendered dimmed). */
    @ColumnInfo(defaultValue = "0") val isError: Boolean = false,
    /**
     * Agent replies: compact tool-step journal, one line per step
     * ("tool · status · 1.2s · preview") — the collapsible journal renders
     * from this after a restart; full detail is fetched lazily from the
     * gateway transcript.
     */
    @ColumnInfo(defaultValue = "NULL") val agentSteps: String? = null,
    /** Pinned by the user (the Telegram-style pin bar above the transcript). */
    @ColumnInfo(defaultValue = "0") val pinned: Boolean = false,
    /** When it was pinned — the bar cycles in PIN order (desktop semantics). */
    @ColumnInfo(defaultValue = "0") val pinnedAt: Long = 0,
)

@Entity(
    tableName = "attachments",
    foreignKeys = [ForeignKey(
        entity = MessageEntity::class,
        parentColumns = ["id"],
        childColumns = ["messageId"],
        onDelete = ForeignKey.CASCADE,
    )],
    indices = [Index("messageId")],
)
data class AttachmentEntity(
    @PrimaryKey val id: String,
    val messageId: String,
    val filename: String,
    val mimeType: String,
    /** Path relative to the app's files directory (images/<id>.jpg). */
    val filePath: String,
    /**
     * Cached OCR extraction, filled the first time the content is needed as
     * text (non-vision provider, or the message aged out of the
     * "attach pixels" window) — retries never re-pay the OCR call.
     */
    val ocrText: String?,
)

@Dao
interface ChatDao {
    // MARK: Conversations

    @Query("SELECT * FROM conversations ORDER BY updatedAt DESC")
    fun conversations(): Flow<List<ConversationEntity>>

    @Query("SELECT * FROM conversations WHERE id = :id")
    suspend fun conversation(id: String): ConversationEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertConversation(conversation: ConversationEntity)

    @Query("DELETE FROM conversations WHERE id = :id")
    suspend fun deleteConversation(id: String)

    @Query("UPDATE conversations SET title = :title, updatedAt = :updatedAt WHERE id = :id")
    suspend fun setTitle(id: String, title: String, updatedAt: Long)

    @Query("UPDATE conversations SET summary = :summary, summaryCoversCount = :coversCount WHERE id = :id")
    suspend fun setSummary(id: String, summary: String?, coversCount: Int)

    @Query("UPDATE conversations SET updatedAt = :updatedAt WHERE id = :id")
    suspend fun touch(id: String, updatedAt: Long)

    // MARK: Messages (windowed)

    /** Most recent `limit` messages, newest first — callers reverse for display. */
    @Query("SELECT * FROM messages WHERE conversationId = :conversationId ORDER BY timestamp DESC, rowid DESC LIMIT :limit")
    suspend fun recentMessages(conversationId: String, limit: Int): List<MessageEntity>

    /** Page of messages strictly older than `beforeTimestamp`, newest first. */
    @Query("SELECT * FROM messages WHERE conversationId = :conversationId AND timestamp < :beforeTimestamp ORDER BY timestamp DESC, rowid DESC LIMIT :limit")
    suspend fun olderMessages(conversationId: String, beforeTimestamp: Long, limit: Int): List<MessageEntity>

    @Query("SELECT COUNT(*) FROM messages WHERE conversationId = :conversationId")
    suspend fun messageCount(conversationId: String): Int

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertMessage(message: MessageEntity)

    @Query("UPDATE messages SET text = :text, isError = :isError WHERE id = :id")
    suspend fun setMessageText(id: String, text: String, isError: Boolean)

    @Query("UPDATE messages SET pinned = :pinned, pinnedAt = :pinnedAt WHERE id = :id")
    suspend fun setPinned(id: String, pinned: Boolean, pinnedAt: Long)

    /** Pinned messages of a conversation in PIN order (the bar's cycle order). */
    @Query("SELECT * FROM messages WHERE conversationId = :conversationId AND pinned = 1 ORDER BY pinnedAt ASC, rowid ASC")
    suspend fun pinnedMessages(conversationId: String): List<MessageEntity>

    /** Conversation mirroring a Hermes session, if any. */
    @Query("SELECT * FROM conversations WHERE hermesSessionId = :sessionId LIMIT 1")
    suspend fun conversationForHermesSession(sessionId: String): ConversationEntity?

    @Query("UPDATE conversations SET hermesSyncedSeq = :seq WHERE id = :id AND hermesSyncedSeq < :seq")
    suspend fun advanceHermesSyncedSeq(id: String, seq: Int)

    /** All Hermes-mirror conversations (the agent thread list). */
    @Query("SELECT * FROM conversations WHERE hermesSessionId IS NOT NULL")
    suspend fun hermesConversations(): List<ConversationEntity>

    /** Full transcript of a conversation, oldest first (files scan / search). */
    @Query("SELECT * FROM messages WHERE conversationId = :conversationId ORDER BY timestamp ASC, rowid ASC")
    suspend fun allMessages(conversationId: String): List<MessageEntity>

    @Query("DELETE FROM messages WHERE id = :id")
    suspend fun deleteMessage(id: String)

    @Query("DELETE FROM messages WHERE conversationId = :conversationId")
    suspend fun deleteMessages(conversationId: String)

    // MARK: Attachments

    @Query("SELECT * FROM attachments WHERE messageId IN (:messageIds)")
    suspend fun attachments(messageIds: List<String>): List<AttachmentEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAttachment(attachment: AttachmentEntity)

    /** Persists a lazily computed OCR extraction onto its attachment. */
    @Query("UPDATE attachments SET ocrText = :ocrText WHERE id = :id")
    suspend fun setAttachmentOCR(id: String, ocrText: String)

    /** File paths of every attachment in a conversation (for cleanup on delete). */
    @Query("SELECT filePath FROM attachments WHERE messageId IN (SELECT id FROM messages WHERE conversationId = :conversationId)")
    suspend fun attachmentPaths(conversationId: String): List<String>

    /** Voice-recording paths in a conversation (for cleanup on clear). */
    @Query("SELECT audioPath FROM messages WHERE conversationId = :conversationId AND audioPath IS NOT NULL")
    suspend fun audioPaths(conversationId: String): List<String>
}

@Database(
    entities = [ConversationEntity::class, MessageEntity::class, AttachmentEntity::class, SpendRecordEntity::class],
    version = 4,
    exportSchema = false,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun chatDao(): ChatDao
    abstract fun spendDao(): SpendDao

    companion object {
        @Volatile private var instance: AppDatabase? = null

        /**
         * 2→3: the spend ledger table. Hand-written — the destructive fallback
         * below would wipe every user's chat history on this upgrade otherwise.
         */
        private val MIGRATION_2_3 = object : androidx.room.migration.Migration(2, 3) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `spend_records` (" +
                        "`id` TEXT NOT NULL, `timestamp` INTEGER NOT NULL, " +
                        "`kind` TEXT NOT NULL, `provider` TEXT NOT NULL, `model` TEXT NOT NULL, " +
                        "`inputTokens` INTEGER NOT NULL, `outputTokens` INTEGER NOT NULL, " +
                        "`cacheReadTokens` INTEGER NOT NULL, `cacheWriteTokens` INTEGER NOT NULL, " +
                        "`reasoningTokens` INTEGER NOT NULL, `units` REAL NOT NULL, " +
                        "`costUSD` REAL, `isEstimate` INTEGER NOT NULL, PRIMARY KEY(`id`))"
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS `index_spend_records_timestamp` ON `spend_records` (`timestamp`)"
                )
            }
        }

        /**
         * 3→4: the Hermes agent addon columns. Hand-written for the same
         * reason as 2→3 — chat history must survive the upgrade.
         */
        private val MIGRATION_3_4 = object : androidx.room.migration.Migration(3, 4) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `conversations` ADD COLUMN `hermesSessionId` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `conversations` ADD COLUMN `hermesSyncedSeq` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `agentSteps` TEXT DEFAULT NULL")
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `pinned` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `messages` ADD COLUMN `pinnedAt` INTEGER NOT NULL DEFAULT 0")
            }
        }

        fun get(context: Context): AppDatabase =
            instance ?: synchronized(this) {
                instance ?: Room.databaseBuilder(
                    // Legacy filename from before the Cuate rename — MUST
                    // stay, or existing installs open an empty database.
                    context.applicationContext, AppDatabase::class.java, "aispotlight.db"
                )
                    .addMigrations(MIGRATION_2_3, MIGRATION_3_4)
                    // Pre-1.0 schema churn: rebuild rather than hand-written
                    // migrations — EXCEPT hops covered by explicit migrations
                    // above, which preserve user data.
                    .fallbackToDestructiveMigration()
                    .build().also { instance = it }
            }
    }
}
