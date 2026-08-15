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
import org.springframework.batch.infrastructure.repeat.RepeatStatus
import org.springframework.beans.factory.annotation.Value
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.transaction.PlatformTransactionManager
import java.time.LocalDateTime
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
        incrementalSourceChangeReaderFactory: IncrementalSourceChangeReaderFactory,
        @Value("#{jobParameters['lowerUpdatedAt']}") lowerUpdatedAt: LocalDateTime,
        @Value("#{jobParameters['lowerGameId']}") lowerGameId: Long,
        @Value("#{jobParameters['upperUpdatedAt']}") upperUpdatedAt: LocalDateTime,
        @Value("#{jobParameters['upperGameId']}") upperGameId: Long,
        @Value("\${stage4.incremental.chunk-size:100}") chunkSize: Int,
    ): JdbcPagingItemReader<IncrementalSourceChange> = incrementalSourceChangeReaderFactory.create(
        lowerUpdatedAt = lowerUpdatedAt,
        lowerGameId = lowerGameId,
        upperUpdatedAt = upperUpdatedAt,
        upperGameId = upperGameId,
        pageSize = chunkSize,
    )

    @Bean
    fun incrementalSourceChangeReaderFactory(dataSource: DataSource): IncrementalSourceChangeReaderFactory =
        IncrementalSourceChangeReaderFactory(dataSource)

    @Bean
    @StepScope
    fun incrementalFailureProcessor(
        @Value("#{jobParameters['failAfterCount'] ?: 0}") failAfterCount: Long,
    ): ItemProcessor<IncrementalSourceChange, IncrementalSourceChange> =
        IncrementalFailureInjector(failAfterCount)

    @Bean
    fun incrementalReadModelWriter(
        projectionUpdater: GameHistoryProjectionUpdater,
    ): ItemWriter<IncrementalSourceChange> = IncrementalReadModelWriter(projectionUpdater)

    @Bean
    @StepScope
    fun advanceIncrementalCheckpointTasklet(
        checkpointStore: IncrementalCheckpointStore,
        @Value("#{jobParameters['upperUpdatedAt']}") upperUpdatedAt: LocalDateTime,
        @Value("#{jobParameters['upperGameId']}") upperGameId: Long,
    ): Tasklet = Tasklet { _, _ ->
        checkpointStore.advanceTo(IncrementalCursor(upperUpdatedAt, upperGameId))
        RepeatStatus.FINISHED
    }
}
