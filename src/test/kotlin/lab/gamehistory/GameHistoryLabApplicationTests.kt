package lab.gamehistory

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.context.annotation.Import
import org.springframework.jdbc.core.JdbcTemplate

@Import(TestcontainersConfiguration::class)
@SpringBootTest
class GameHistoryLabApplicationTests {

    @Autowired
    private lateinit var jdbcTemplate: JdbcTemplate

    @Test
    fun connectsToMySql() {
        val result = jdbcTemplate.queryForObject("SELECT 1", Int::class.java)

        assertEquals(1, result)
    }
}

