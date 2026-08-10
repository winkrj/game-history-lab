package lab.gamehistory.history

import lab.gamehistory.TestcontainersConfiguration
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.context.annotation.Import
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.test.context.jdbc.Sql
import java.time.Instant

@Import(TestcontainersConfiguration::class)
@SpringBootTest
@Sql("/original-game-history-fixture.sql")
class OriginalGameHistoryQueryIntegrationTests {

    @Autowired
    private lateinit var query: OriginalGameHistoryQuery

    @Autowired
    private lateinit var jdbcTemplate: JdbcTemplate

    @Test
    fun aggregatesGameHistoryFromNormalizedSourceTables() {
        val result = query.findByShopAndPeriod(
            shopId = 1,
            fromInclusive = Instant.parse("2026-01-01T00:00:00Z"),
            toExclusive = Instant.parse("2026-02-01T00:00:00Z"),
            limit = 10,
            offset = 0,
        )

        assertEquals(
            listOf(
                OriginalGameHistory(
                    gameId = 101,
                    shopId = 1,
                    playedAt = Instant.parse("2026-01-03T10:00:00Z"),
                    playerNickname = "bob",
                    courseName = "Hill Course",
                    totalScore = 0,
                    roundCount = 0,
                    gameStatus = "CANCELLED",
                ),
                OriginalGameHistory(
                    gameId = 100,
                    shopId = 1,
                    playedAt = Instant.parse("2026-01-03T10:00:00Z"),
                    playerNickname = "alice",
                    courseName = "Lake Course",
                    totalScore = 25,
                    roundCount = 2,
                    gameStatus = "COMPLETED",
                ),
                OriginalGameHistory(
                    gameId = 102,
                    shopId = 1,
                    playedAt = Instant.parse("2026-01-01T00:00:00Z"),
                    playerNickname = "carol",
                    courseName = "Forest Course",
                    totalScore = 0,
                    roundCount = 1,
                    gameStatus = "IN_PROGRESS",
                ),
            ),
            result,
        )
    }

    @Test
    fun appliesDeterministicOrderAndPagination() {
        val result = query.findByShopAndPeriod(
            shopId = 1,
            fromInclusive = Instant.parse("2026-01-01T00:00:00Z"),
            toExclusive = Instant.parse("2026-02-01T00:00:00Z"),
            limit = 2,
            offset = 1,
        )

        assertEquals(listOf(100L, 102L), result.map { it.gameId })
    }

    @Test
    fun rejectsRoundWithoutGame() {
        assertThrows<DataIntegrityViolationException> {
            jdbcTemplate.update(
                "INSERT INTO rounds (id, game_id, round_number) VALUES (?, ?, ?)",
                9999,
                9999,
                1,
            )
        }
    }
}

