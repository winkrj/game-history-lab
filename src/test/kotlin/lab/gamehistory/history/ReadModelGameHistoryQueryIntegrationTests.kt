package lab.gamehistory.history

import lab.gamehistory.TestcontainersConfiguration
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.context.annotation.Import
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.test.context.jdbc.Sql
import java.time.Instant

@Import(TestcontainersConfiguration::class)
@SpringBootTest
@Sql(scripts = ["/original-game-history-fixture.sql", "/stage2-rebuild-read-model.sql"])
class ReadModelGameHistoryQueryIntegrationTests {

    @Autowired
    private lateinit var originalQuery: OriginalGameHistoryQuery

    @Autowired
    private lateinit var readModelQuery: ReadModelGameHistoryQuery

    @Autowired
    private lateinit var jdbcTemplate: JdbcTemplate

    @Test
    fun matchesOriginalJoinFieldsOrderPeriodAndPagination() {
        assertEquals(
            jdbcTemplate.queryForObject("SELECT COUNT(*) FROM games", Long::class.java),
            jdbcTemplate.queryForObject("SELECT COUNT(*) FROM game_history_read_model", Long::class.java),
        )

        val cases = listOf(
            QueryCase("2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", 10, 0),
            QueryCase("2026-01-03T10:00:00Z", "2026-02-01T00:00:00Z", 1, 0),
            QueryCase("2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z", 2, 1),
            QueryCase("2026-01-01T00:00:00Z", "2026-01-03T10:00:00Z", 10, 0),
        )

        cases.forEach { case ->
            val original = originalQuery.findByShopAndPeriod(
                shopId = 1,
                fromInclusive = Instant.parse(case.from),
                toExclusive = Instant.parse(case.to),
                limit = case.limit,
                offset = case.offset,
            )
            val readModel = readModelQuery.findByShopAndPeriod(
                shopId = 1,
                fromInclusive = Instant.parse(case.from),
                toExclusive = Instant.parse(case.to),
                limit = case.limit,
                offset = case.offset,
            )

            assertEquals(original, readModel)
        }
    }

    private data class QueryCase(
        val from: String,
        val to: String,
        val limit: Int,
        val offset: Long,
    )
}
