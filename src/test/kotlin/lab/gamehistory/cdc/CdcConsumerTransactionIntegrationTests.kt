package lab.gamehistory.cdc

import lab.gamehistory.TestcontainersConfiguration
import lab.gamehistory.projection.GameHistoryProjectionUpdater
import org.apache.kafka.clients.consumer.ConsumerRecord
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.aop.support.AopUtils
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Import
import org.springframework.core.io.ClassPathResource
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.jdbc.datasource.init.ScriptUtils
import javax.sql.DataSource

@Import(TestcontainersConfiguration::class, CdcConsumerTransactionIntegrationTests.ConsumerTestConfiguration::class)
@SpringBootTest(
    properties = [
        "spring.autoconfigure.exclude=org.springframework.boot.kafka.autoconfigure.KafkaAutoConfiguration",
        "stage5.cdc.fail-on-game-id=100",
    ],
)
class CdcConsumerTransactionIntegrationTests {

    @Autowired
    private lateinit var dataSource: DataSource

    @Autowired
    private lateinit var jdbcTemplate: JdbcTemplate

    @Autowired
    private lateinit var recordParser: DebeziumRecordParser

    @Autowired
    private lateinit var affectedGameResolver: CdcAffectedGameResolver

    @Autowired
    private lateinit var projectionUpdater: GameHistoryProjectionUpdater

    @Autowired
    private lateinit var consumer: GameHistoryCdcConsumer

    @BeforeEach
    fun prepareFixture() {
        dataSource.connection.use { connection ->
            ScriptUtils.executeSqlScript(connection, ClassPathResource("original-game-history-fixture.sql"))
            ScriptUtils.executeSqlScript(connection, ClassPathResource("stage2-rebuild-read-model.sql"))
        }
    }

    @Test
    fun rollsBackProjectionAndAllowsTheSameRecordToConvergeOnReplay() {
        jdbcTemplate.update("UPDATE games SET game_status = 'CANCELLED' WHERE id = 100")
        val record = ConsumerRecord(
            "game-history.game_history_lab.games",
            0,
            42,
            "100",
            event("games", "u", "\"id\":100"),
        )

        assertTrue(AopUtils.isAopProxy(consumer))
        assertThrows(IllegalStateException::class.java) { consumer.consume(record) }
        assertEquals("COMPLETED", gameStatus(100))

        consumer.consume(record)

        assertEquals("CANCELLED", gameStatus(100))
    }

    private fun gameStatus(gameId: Long): String = jdbcTemplate.queryForObject(
        "SELECT game_status FROM game_history_read_model WHERE game_id = ?",
        String::class.java,
        gameId,
    )!!

    private fun event(table: String, operation: String, rowFields: String): String = """
        {
          "before": null,
          "after": {$rowFields},
          "source": {"table": "$table", "ts_ms": 1786550400000},
          "op": "$operation"
        }
    """.trimIndent()

    @TestConfiguration(proxyBeanMethods = false)
    class ConsumerTestConfiguration {

        @Bean
        fun cdcFailureInjector(): CdcFailureInjector = CdcFailureInjector(failOnGameId = 100)

        @Bean
        fun gameHistoryCdcConsumer(
            recordParser: DebeziumRecordParser,
            affectedGameResolver: CdcAffectedGameResolver,
            projectionUpdater: GameHistoryProjectionUpdater,
            failureInjector: CdcFailureInjector,
        ): GameHistoryCdcConsumer = GameHistoryCdcConsumer(
            recordParser = recordParser,
            affectedGameResolver = affectedGameResolver,
            projectionUpdater = projectionUpdater,
            failureInjector = failureInjector,
        )
    }
}
