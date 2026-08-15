package lab.gamehistory.history

import org.springframework.jdbc.core.RowMapper
import java.sql.ResultSet
import java.time.LocalDateTime
import java.time.ZoneOffset

object GameHistoryRowMapper : RowMapper<GameHistoryResult> {
    override fun mapRow(resultSet: ResultSet, rowNumber: Int): GameHistoryResult =
        GameHistoryResult(
            gameId = resultSet.getLong("game_id"),
            shopId = resultSet.getLong("shop_id"),
            playedAt = resultSet
                .getObject("played_at", LocalDateTime::class.java)
                .toInstant(ZoneOffset.UTC),
            playerNickname = resultSet.getString("player_nickname"),
            courseName = resultSet.getString("course_name"),
            totalScore = resultSet.getLong("total_score"),
            roundCount = resultSet.getLong("round_count"),
            gameStatus = resultSet.getString("game_status"),
        )
}
