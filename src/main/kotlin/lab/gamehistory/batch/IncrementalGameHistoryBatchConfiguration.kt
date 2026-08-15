package lab.gamehistory.batch

import lab.gamehistory.projection.GameHistoryProjectionUpdater
import org.springframework.batch.core.configuration.annotation.StepScope
import org.springframework.batch.core.job.Job
import org.springframework.batch.core.job.builder.JobBuilder
import org.springframework.batch.core.repository.JobRepository
import org.springframework.batch.core.step.Step
import org.springframework.batch.core.step.builder.StepBuilder
import org.springframework.batch.core.step.tasklet.Tasklet
import org.springframework.batch.infrastructure.item.ItemProcessor
import org.springframework.batch.infrastructure.item.ItemWriter
import org.springframework.batch.infrastructure.item.database.JdbcPagingItemReader
import org.springframework.batch.infrastructure.item.database.Order
import org.springframework.batch.infrastructure.item.database.builder.JdbcPagingItemReaderBuilder
import org.springframework.batch.infrastructure.repeat.RepeatStatus
import org.springframework.beans.factory.annotation.Value
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.transaction.PlatformTransactionManager
import java.time.LocalDateTime
import java.util.concurrent.atomic.AtomicLong
import javax.sql.DataSource

@Configuration
class IncrementalGameHistoryBatchConfiguration {

    @Bean
    fun incrementalGameHistoryReadModelJob(
        jobRepository: JobRepository,
        processIncrementalChangesStep: Step,
        advanceIncrementalCheckpointStep: Step,
    ): Job = JobBuilder("incrementalGameHistoryReadModelJob", jobRepository)
        .start(processIncrementalChangesStep)
        .next(advanceIncrementalCheckpointStep)
        .build()

    @Bean
    fun processIncrementalChangesStep(
        jobRepository: JobRepository,
        transactionManager: PlatformTransactionManager,
        incrementalSourceChangeReader: JdbcPagingItemReader<IncrementalSourceChange>,
        incrementalFailureProcessor: ItemProcessor<IncrementalSourceChange, IncrementalSourceChange>,
        incrementalReadModelWriter: ItemWriter<IncrementalSourceChange>,
        @Value("\${stage4.incremental.chunk-size:100}") chunkSize: Int,
    ): Step = StepBuilder("processIncrementalChangesStep", jobRepository)
        .chunk<IncrementalSourceChange, IncrementalSourceChange>(chunkSize)
        .transactionManager(transactionManager)
        .reader(incrementalSourceChangeReader)
        .processor(incrementalFailureProcessor)
        .writer(incrementalReadModelWriter)
        .build()

    @Bean
    fun advanceIncrementalCheckpointStep(
        jobRepository: JobRepository,
        transactionManager: PlatformTransactionManager,
        advanceIncrementalCheckpointTasklet: Tasklet,
    ): Step = StepBuilder("advanceIncrementalCheckpointStep", jobRepository)
        .tasklet(advanceIncrementalCheckpointTasklet, transactionManager)
        .build()

    @Bean
    @StepScope
    fun incrementalSourceChangeReader(
        dataSource: DataSource,
        @Value("#{jobParameters['lowerUpdatedAt']}") lowerUpdatedAt: LocalDateTime,
        @Value("#{jobParameters['lowerGameId']}") lowerGameId: Long,
        @Value("#{jobParameters['upperUpdatedAt']}") upperUpdatedAt: LocalDateTime,
        @Value("#{jobParameters['upperGameId']}") upperGameId: Long,
        @Value("\${stage4.incremental.chunk-size:100}") chunkSize: Int,
    ): JdbcPagingItemReader<IncrementalSourceChange> =
        JdbcPagingItemReaderBuilder<IncrementalSourceChange>()
            .name("incrementalSourceChangeReader")
            .dataSource(dataSource)
            .selectClause("game_id, MAX(changed_at) AS changed_at")
            .fromClause(SOURCE_CHANGES)
            .groupClause("game_id")
            .sortKeys(linkedMapOf("changed_at" to Order.ASCENDING, "game_id" to Order.ASCENDING))
            .parameterValues(
                mapOf(
                    "lowerUpdatedAt" to lowerUpdatedAt,
                    "lowerGameId" to lowerGameId,
                    "upperUpdatedAt" to upperUpdatedAt,
                    "upperGameId" to upperGameId,
                ),
            )
            .pageSize(chunkSize)
            .fetchSize(chunkSize)
            .saveState(true)
            .rowMapper { resultSet, _ ->
                IncrementalSourceChange(
                    gameId = resultSet.getLong("game_id"),
                    changedAt = resultSet.getObject("changed_at", LocalDateTime::class.java),
                )
            }
            .build()

    @Bean
    @StepScope
    fun incrementalFailureProcessor(
        @Value("#{jobParameters['failAfterCount'] ?: 0}") failAfterCount: Long,
    ): ItemProcessor<IncrementalSourceChange, IncrementalSourceChange> {
        val processedCount = AtomicLong()
        return ItemProcessor { change ->
            val currentCount = processedCount.incrementAndGet()
            if (failAfterCount > 0 && currentCount >= failAfterCount) {
                throw IllegalStateException(
                    "Deterministic incremental failure after count=$currentCount gameId=${change.gameId}",
                )
            }
            change
        }
    }

    @Bean
    fun incrementalReadModelWriter(
        projectionUpdater: GameHistoryProjectionUpdater,
    ): ItemWriter<IncrementalSourceChange> = IncrementalReadModelWriter(projectionUpdater)

    @Bean
    @StepScope
    fun advanceIncrementalCheckpointTasklet(
        jdbcTemplate: JdbcTemplate,
        @Value("#{jobParameters['upperUpdatedAt']}") upperUpdatedAt: LocalDateTime,
        @Value("#{jobParameters['upperGameId']}") upperGameId: Long,
    ): Tasklet = Tasklet { _, _ ->
        jdbcTemplate.update(
            """
                UPDATE incremental_read_model_checkpoint
                SET cursor_updated_at = ?, cursor_game_id = ?
                WHERE checkpoint_name = 'game-history'
                  AND (
                      cursor_updated_at < ?
                      OR (cursor_updated_at = ? AND cursor_game_id < ?)
                  )
            """.trimIndent(),
            upperUpdatedAt,
            upperGameId,
            upperUpdatedAt,
            upperUpdatedAt,
            upperGameId,
        )
        RepeatStatus.FINISHED
    }

    private companion object {
        val CHANGE_BOUNDS = """
            (
                updated_at > :lowerUpdatedAt
                OR (updated_at = :lowerUpdatedAt AND game_id > :lowerGameId)
            )
            AND (
                updated_at < :upperUpdatedAt
                OR (updated_at = :upperUpdatedAt AND game_id <= :upperGameId)
            )
        """.trimIndent()

        val SOURCE_CHANGES = """
            (
                SELECT g.id AS game_id, g.updated_at AS changed_at
                FROM games g
                WHERE ${CHANGE_BOUNDS.replace("game_id", "g.id")}

                UNION ALL

                SELECT r.game_id, r.updated_at AS changed_at
                FROM rounds r
                WHERE ${CHANGE_BOUNDS.replace("game_id", "r.game_id")}

                UNION ALL

                SELECT r.game_id, rs.updated_at AS changed_at
                FROM round_scores rs
                JOIN rounds r ON r.id = rs.round_id
                WHERE ${CHANGE_BOUNDS.replace("updated_at", "rs.updated_at").replace("game_id", "r.game_id")}
            ) source_changes
        """.trimIndent()
    }
}
