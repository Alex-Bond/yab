package dev.yab.agent

/** Immutable upstream artifacts. Runtime and answer quality require separate device acceptance. */
object LocalModelCatalog {
    data class Model(val name: String, val url: String, val bytes: Long, val sha256: String, val license: String, val source: String)
    val smokeTest = Model(
        name = "SmolLM2 135M · test model",
        url = "https://huggingface.co/litert-community/SmolLM2-135M-Instruct/resolve/8111e0a65fda719f0a6855e8e1a8ec8c3f9ccb22/SmolLM2_135M_Instruct.litertlm",
        bytes = 142_819_328,
        sha256 = "ccdc5c85735743f081b7d44ca309cab569f76c0f2f0e8e163449a63721969c37",
        license = "Apache-2.0",
        source = "https://huggingface.co/litert-community/SmolLM2-135M-Instruct/tree/8111e0a65fda719f0a6855e8e1a8ec8c3f9ccb22",
    )
    val compact = Model(
        name = "Qwen3 0.6B",
        url = "https://huggingface.co/litert-community/Qwen3-0.6B/resolve/e6687177e00897731e7716267eebd4eba0dde7c2/Qwen3-0.6B.litertlm",
        bytes = 613_722_264,
        sha256 = "c5f39b4191926786c3e6668b62af4d6eb15248dfc7a5348252a9b406f33f2108",
        license = "Apache-2.0",
        source = "https://huggingface.co/litert-community/Qwen3-0.6B/tree/e6687177e00897731e7716267eebd4eba0dde7c2",
    )
    val full = Model(
        name = "SmolLM3 3B",
        url = "https://huggingface.co/litert-community/SmolLM3-3B/resolve/282baa69693339f07d24938fd08ce45a6b08aeeb/SmolLM3-3B_q4_block32_ekv4096.litertlm",
        bytes = 2_004_633_520,
        sha256 = "bdd7eb05b6764fb5a5173bdbdd59354a26f66e4c20b040f0d3da3532071d18f6",
        license = "Apache-2.0",
        source = "https://huggingface.co/litert-community/SmolLM3-3B/tree/282baa69693339f07d24938fd08ce45a6b08aeeb",
    )
    val available = listOf(compact, full)
}
