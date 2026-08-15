import http from "k6/http";
import { check } from "k6";

const cases = {
    shop1_recent7d_page0: {
        from: "2025-12-25T00:00:00Z",
        to: "2026-01-01T00:00:00Z",
        page: 0,
        size: 20,
    },
    shop1_recent3mo_page0: {
        from: "2025-10-01T00:00:00Z",
        to: "2026-01-01T00:00:00Z",
        page: 0,
        size: 20,
    },
    shop1_recent3mo_page100: {
        from: "2025-10-01T00:00:00Z",
        to: "2026-01-01T00:00:00Z",
        page: 100,
        size: 20,
    },
};

const caseId = __ENV.BENCHMARK_CASE;
const queryCase = cases[caseId];

if (!queryCase) {
    throw new Error(`Unknown BENCHMARK_CASE: ${caseId}`);
}

const vus = Number(__ENV.BENCHMARK_VUS || 4);
const iterationsPerVu = Number(__ENV.ITERATIONS_PER_VU || 50);
const baseUrl = __ENV.BASE_URL || "http://localhost:8080";

export const options = {
    scenarios: {
        benchmark: {
            executor: "per-vu-iterations",
            vus,
            iterations: iterationsPerVu,
            maxDuration: "15m",
        },
    },
    summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
    thresholds: {
        checks: ["rate==1"],
        http_req_failed: ["rate==0"],
    },
    tags: {
        benchmark_case: caseId,
    },
};

export default function () {
    const query = [
        `from=${encodeURIComponent(queryCase.from)}`,
        `to=${encodeURIComponent(queryCase.to)}`,
        `page=${queryCase.page}`,
        `size=${queryCase.size}`,
    ].join("&");
    const response = http.get(`${baseUrl}/shops/1/games?${query}`);

    check(response, {
        "status is 200": (result) => result.status === 200,
        "response has requested page size": (result) => {
            try {
                return result.json().length === queryCase.size;
            } catch (_) {
                return false;
            }
        },
    });
}

