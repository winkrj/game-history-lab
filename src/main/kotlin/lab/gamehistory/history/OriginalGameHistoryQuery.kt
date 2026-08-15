package lab.gamehistory.history

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate
import org.springframework.stereotype.Repository
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset

@Repository
class OriginalGameHistoryQuery(
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
                g.id AS game_id,
                s.id AS shop_id,
                g.played_at,
                g.player_nickname,
                g.course_name,
                COALESCE(SUM(rs.score), 0) AS total_score,
                COUNT(DISTINCT r.id) AS round_count,
                g.game_status
            FROM games g
            JOIN shops s ON s.id = g.shop_id
            LEFT JOIN rounds r ON r.game_id = g.id
            LEFT JOIN round_scores rs ON rs.round_id = r.id
            WHERE s.id = :shopId
              AND g.played_at >= :fromInclusive
              AND g.played_at < :toExclusive
            GROUP BY
                g.id,
                s.id,
                g.played_at,
                g.player_nickname,
                g.course_name,
                g.game_status
            ORDER BY g.played_at DESC, g.id DESC
            LIMIT :limit OFFSET :offset
        """.trimIndent()
    }
}
