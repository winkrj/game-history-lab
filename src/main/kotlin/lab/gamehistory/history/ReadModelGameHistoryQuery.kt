package lab.gamehistory.history

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate
import org.springframework.stereotype.Repository
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset

@Repository
class ReadModelGameHistoryQuery(
    private val jdbcTemplate: NamedParameterJdbcTemplate,
) {

    fun findByShopAndPeriod(
        shopId: Long,
        fromInclusive: Instant,
        toExclusive: Instant,
        limit: Int,
        offset: Long,
    ): List<GameHistoryResult> {
        require(fromInclusive < toExclusive) { "fromInclusive must be earlier than toExclusive" }
        require(limit > 0) { "limit must be positive" }
        require(offset >= 0) { "offset must not be negative" }

        val parameters = MapSqlParameterSource()
            .addValue("shopId", shopId)
            .addValue("fromInclusive", LocalDateTime.ofInstant(fromInclusive, ZoneOffset.UTC))
            .addValue("toExclusive", LocalDateTime.ofInstant(toExclusive, ZoneOffset.UTC))
            .addValue("limit", limit)
            .addValue("offset", offset)

        return jdbcTemplate.query(SELECT_GAME_HISTORY, parameters, GameHistoryRowMapper)
    }

    private companion object {
        val SELECT_GAME_HISTORY = """
            SELECT
                game_id,
                shop_id,
                played_at,
                player_nickname,
                course_name,
                total_score,
                round_count,
                game_status
            FROM game_history_read_model
            WHERE shop_id = :shopId
              AND played_at >= :fromInclusive
              AND played_at < :toExclusive
            ORDER BY played_at DESC, game_id DESC
            LIMIT :limit OFFSET :offset
        """.trimIndent()
    }
}
