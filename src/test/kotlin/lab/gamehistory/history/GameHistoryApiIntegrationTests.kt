package lab.gamehistory.history

import lab.gamehistory.TestcontainersConfiguration
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc
import org.springframework.context.annotation.Import
import org.springframework.test.context.jdbc.Sql
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status

@Import(TestcontainersConfiguration::class)
@SpringBootTest
@AutoConfigureMockMvc
@Sql("/original-game-history-fixture.sql")
class GameHistoryApiIntegrationTests {

    @Autowired
    private lateinit var mockMvc: MockMvc

    @Test
    fun returnsAggregatedGameHistoryForTheRequestedPeriod() {
        mockMvc.perform(
            get("/shops/{shopId}/games", 1)
                .param("from", "2026-01-01T00:00:00Z")
                .param("to", "2026-02-01T00:00:00Z"),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.length()").value(3))
            .andExpect(jsonPath("$[0].gameId").value(101))
            .andExpect(jsonPath("$[0].shopId").value(1))
            .andExpect(jsonPath("$[0].playedAt").value("2026-01-03T10:00:00Z"))
            .andExpect(jsonPath("$[0].playerNickname").value("bob"))
            .andExpect(jsonPath("$[0].courseName").value("Hill Course"))
            .andExpect(jsonPath("$[0].totalScore").value(0))
            .andExpect(jsonPath("$[0].roundCount").value(0))
            .andExpect(jsonPath("$[0].gameStatus").value("CANCELLED"))
            .andExpect(jsonPath("$[1].gameId").value(100))
            .andExpect(jsonPath("$[1].totalScore").value(25))
            .andExpect(jsonPath("$[1].roundCount").value(2))
            .andExpect(jsonPath("$[2].gameId").value(102))
            .andExpect(jsonPath("$[2].totalScore").value(0))
            .andExpect(jsonPath("$[2].roundCount").value(1))
    }

    @Test
    fun appliesPageAndSizeToTheQuery() {
        mockMvc.perform(
            get("/shops/{shopId}/games", 1)
                .param("from", "2026-01-01T00:00:00Z")
                .param("to", "2026-02-01T00:00:00Z")
                .param("page", "1")
                .param("size", "2"),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.length()").value(1))
            .andExpect(jsonPath("$[0].gameId").value(102))
    }

    @Test
    fun rejectsInvalidPeriodAndPagination() {
        mockMvc.perform(
            get("/shops/{shopId}/games", 1)
                .param("from", "2026-02-01T00:00:00Z")
                .param("to", "2026-01-01T00:00:00Z"),
        )
            .andExpect(status().isBadRequest)

        mockMvc.perform(
            get("/shops/{shopId}/games", 1)
                .param("from", "2026-01-01T00:00:00Z")
                .param("to", "2026-02-01T00:00:00Z")
                .param("size", "0"),
        )
            .andExpect(status().isBadRequest)
    }
}

