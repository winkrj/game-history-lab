package lab.gamehistory.batch

import org.springframework.batch.core.job.Job
import org.springframework.batch.core.job.builder.JobBuilder
import org.springframework.batch.core.configuration.annotation.EnableBatchProcessing
import org.springframework.batch.core.configuration.annotation.EnableJdbcJobRepository
import org.springframework.batch.core.repository.JobRepository
import org.springframework.batch.core.step.Step
import org.springframework.batch.core.step.builder.StepBuilder
import org.springframework.batch.infrastructure.item.ItemProcessor
import org.springframework.batch.infrastructure.item.ItemWriter
import org.springframework.batch.infrastructure.item.database.JdbcPagingItemReader
import org.springframework.batch.infrastructure.item.database.builder.JdbcPagingItemReaderBuilder
import org.springframework.batch.infrastructure.item.database.Order
import org.springframework.beans.factory.annotation.Value
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.batch.core.configuration.annotation.StepScope
import org.springframework.transaction.PlatformTransactionManager
import javax.sql.DataSource

@Configuration
@EnableBatchProcessing
@EnableJdbcJobRepository
class GameHistoryReadModelBatchConfiguration {

    @Bean
    fun gameHistoryReadModelJob(
        jobRepository: JobRepository,
        buildReadModelStep: Step,
    ): Job = JobBuilder("gameHistoryReadModelJob", jobRepository)
        .start(buildReadModelStep)
        .build()

    @Bean
    fun buildReadModelStep(
        jobRepository: JobRepository,
        transactionManager: PlatformTransactionManager,
        readModelSourceReader: JdbcPagingItemReader<Long>,
        failureInjectingProcessor: ItemProcessor<Long, Long>,
        readModelWriter: ItemWriter<Long>,
        @Value("\${stage3.batch.chunk-size:1000}") chunkSize: Int,
    ): Step = StepBuilder("buildReadModelStep", jobRepository)
        .chunk<Long, Long>(chunkSize, transactionManager)
        .reader(readModelSourceReader)
        .processor(failureInjectingProcessor)
        .writer(readModelWriter)
        .build()

    @Bean
    @StepScope
    fun readModelSourceReader(
        dataSource: DataSource,
        @Value("#{jobParameters['minGameId']}") minGameId: Long,
        @Value("#{jobParameters['maxGameId']}") maxGameId: Long,
        @Value("\${stage3.batch.chunk-size:1000}") chunkSize: Int,
    ): JdbcPagingItemReader<Long> = JdbcPagingItemReaderBuilder<Long>()
        .name("readModelSourceReader")
        .dataSource(dataSource)
        .selectClause(SELECT_SOURCE_PROJECTION)
        .fromClause(SOURCE_FROM)
        .whereClause("g.id BETWEEN :minGameId AND :maxGameId")
        .sortKeys(linkedMapOf("id" to Order.ASCENDING))
        .parameterValues(mapOf("minGameId" to minGameId, "maxGameId" to maxGameId))
        .pageSize(chunkSize)
        .fetchSize(chunkSize)
        .saveState(true)
        .rowMapper { resultSet, _ -> resultSet.getLong("game_id") }
        .build()

    @Bean
    @StepScope
    fun failureInjectingProcessor(
        @Value("#{jobParameters['failAfterGameId'] ?: 0}") failAfterGameId: Long,
    ): ItemProcessor<Long, Long> = ItemProcessor { gameId ->
        if (failAfterGameId > 0 && gameId >= failAfterGameId) {
            throw IllegalStateException("Deterministic failure at gameId=$gameId")
        }
        gameId
    }

    @Bean
    fun readModelWriter(jdbcTemplate: org.springframework.jdbc.core.JdbcTemplate): ItemWriter<Long> =
        ReadModelChunkWriter(jdbcTemplate)

    private companion object {
        val SELECT_SOURCE_PROJECTION = """
                g.id AS game_id,
                g.id AS id
        """.trimIndent()

        const val SOURCE_FROM = "games g"
    }
}
