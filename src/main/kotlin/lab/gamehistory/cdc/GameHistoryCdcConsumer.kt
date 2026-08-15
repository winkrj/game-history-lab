package lab.gamehistory.cdc

import lab.gamehistory.projection.GameHistoryProjectionUpdater
import org.apache.kafka.clients.consumer.ConsumerRecord
import org.slf4j.LoggerFactory
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.kafka.annotation.KafkaListener
import org.springframework.stereotype.Component
import org.springframework.transaction.annotation.Transactional
import org.springframework.transaction.support.TransactionSynchronization
import org.springframework.transaction.support.TransactionSynchronizationManager
import java.time.Instant

@Component
@ConditionalOnProperty(name = ["stage5.cdc.enabled"], havingValue = "true")
class GameHistoryCdcConsumer(
    private val recordParser: DebeziumRecordParser,
    private val affectedGameResolver: CdcAffectedGameResolver,
    private val projectionUpdater: GameHistoryProjectionUpdater,
    private val failureInjector: CdcFailureInjector,
) {

    @KafkaListener(
        topics = [
            "\${stage5.cdc.topic.games:game-history.game_history_lab.games}",
            "\${stage5.cdc.topic.rounds:game-history.game_history_lab.rounds}",
            "\${stage5.cdc.topic.round-scores:game-history.game_history_lab.round_scores}",
        ],
        containerFactory = "stage5KafkaListenerContainerFactory",
    )
    @Transactional("transactionManager")
    fun consume(record: ConsumerRecord<String, String>) {
        val parsedRecord = recordParser.parse(record.value()) ?: return
        val affectedGame = affectedGameResolver.resolve(parsedRecord)
        val receivedAtMillis = Instant.now().toEpochMilli()

        projectionUpdater.upsertGames(listOf(affectedGame.gameId))
        failureInjector.afterProjectionUpdate(affectedGame.gameId)

        TransactionSynchronizationManager.registerSynchronization(
            object : TransactionSynchronization {
                override fun afterCommit() {
                    val visibleAtMillis = Instant.now().toEpochMilli()
                    logger.info(
                        "STAGE5_CDC_APPLIED topic={} partition={} offset={} table={} operation={} " +
                            "gameId={} sourceTsMs={} receivedAtMs={} visibleAtMs={}",
                        record.topic(),
                        record.partition(),
                        record.offset(),
                        affectedGame.sourceTable,
                        affectedGame.operation,
                        affectedGame.gameId,
                        affectedGame.sourceTimestampMillis,
                        receivedAtMillis,
                        visibleAtMillis,
                    )
                }
            },
        )
    }

    private companion object {
        val logger = LoggerFactory.getLogger(GameHistoryCdcConsumer::class.java)
    }
}
