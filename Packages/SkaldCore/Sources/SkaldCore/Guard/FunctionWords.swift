public enum FunctionWords {
    public static func contains(_ word: String, _ language: Language) -> Bool {
        words[language]!.contains(word.lowercased())
    }

    static func isAuxiliary(_ word: String, _ language: Language) -> Bool {
        auxiliaries[language]!.contains(word.lowercased())
    }

    private static let auxiliaries: [Language: Set<String>] = [
        .en: ["have", "has", "had", "having", "ve"],
        .nl: [
            "heb", "hebt", "heeft", "hebben", "had", "hadden", "hebbende",
            "ben", "bent", "is", "zijn", "was", "waren",
        ],
        .fr: [
            "ai", "as", "a", "avons", "avez", "ont", "avais", "avait", "avions", "aviez", "avaient",
            "suis", "es", "est", "sommes", "êtes", "sont", "étais", "était", "étions", "étiez", "étaient",
        ],
    ]

    private static let words: [Language: Set<String>] = [
        .en: auxiliaries[.en]!.union([
            "a", "an", "the",
            "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves", "you", "your", "yours",
            "yourself", "he", "him", "his", "himself", "she", "her", "hers", "herself", "it", "its", "itself",
            "they", "them", "their", "theirs", "themselves", "this", "that", "these", "those",
            "who", "whom", "whose", "which", "what", "there", "here",
            "and", "or", "but", "nor", "so", "yet", "if", "because", "although", "though", "while", "whereas",
            "than", "then", "as", "when", "where", "why", "how",
            "of", "in", "on", "at", "by", "for", "with", "about", "against", "between", "into", "through",
            "during", "before", "after", "above", "below", "to", "from", "up", "down", "out", "off", "over",
            "under", "again", "per", "via",
            "am", "is", "are", "was", "were", "be", "been", "being", "do", "does", "did", "done", "doing",
            "will", "would", "shall", "should", "can", "could", "may", "might", "must",
            "not", "no", "too", "very", "also", "just", "only", "all", "any", "each", "few", "more", "most",
            "other", "some", "such", "own", "same",
            "s", "t", "ll", "re", "d", "m",
        ]),
        .nl: auxiliaries[.nl]!.union([
            "de", "het", "een", "'t", "'n",
            "ik", "mij", "me", "mijn", "m'n", "jij", "je", "jou", "jouw", "u", "uw", "hij", "hem", "zij",
            "ze", "haar", "hun", "hen", "wij", "we", "ons", "onze", "jullie", "men", "zich", "zelf",
            "die", "dat", "deze", "dit", "wie", "wat", "welk", "welke", "er", "hier", "daar", "waar",
            "en", "of", "maar", "want", "dus", "dan", "als", "omdat", "hoewel", "terwijl", "toen", "zodat",
            "indien", "tot", "noch", "doch",
            "in", "op", "aan", "van", "voor", "met", "door", "naar", "uit", "bij", "over", "onder", "tegen",
            "na", "om", "zonder", "tussen", "tijdens", "binnen", "buiten", "naast", "achter", "boven", "langs",
            "worden", "word", "wordt", "werd", "werden", "geworden", "zullen", "zal", "zult", "zul", "zou",
            "zouden", "kunnen", "kan", "kunt", "kon", "konden", "willen", "wil", "wilt", "wou", "wilde",
            "wilden", "moeten", "moet", "moest", "moesten", "mogen", "mag", "mocht", "mochten", "geweest",
            "gehad",
            "niet", "geen", "ook", "nog", "al", "zo", "te", "wel", "nu", "reeds", "toch",
        ]),
        .fr: auxiliaries[.fr]!.union([
            "le", "la", "les", "l", "un", "une", "des", "du", "de", "d", "au", "aux",
            "je", "j", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "me", "m", "te", "t", "se",
            "s", "lui", "leur", "leurs", "moi", "toi", "soi", "eux", "y", "en",
            "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "notre", "nos", "votre", "vos",
            "ce", "c", "cet", "cette", "ces", "ceci", "cela", "ça", "celui", "celle", "ceux", "celles",
            "qui", "que", "qu", "quoi", "dont", "où", "lequel", "laquelle", "lesquels", "lesquelles",
            "ou", "et", "mais", "donc", "or", "ni", "car", "si", "comme", "quand", "lorsque", "puisque",
            "parce", "alors", "ainsi",
            "à", "dans", "sur", "sous", "par", "pour", "avec", "sans", "chez", "vers", "entre", "contre",
            "depuis", "pendant", "avant", "après", "devant", "derrière",
            "été", "étant", "serai", "seras", "sera", "serons", "serez", "seront", "serais", "serait",
            "serions", "seriez", "seraient", "soit", "soient", "sois", "eu", "aurai", "auras", "aura",
            "aurons", "aurez", "auront", "aurais", "aurait", "aurions", "auriez", "auraient", "ait", "aient",
            "ne", "n", "pas", "plus", "jamais", "rien", "très", "aussi", "bien", "tout", "tous", "toute",
            "toutes", "même", "autre", "autres",
        ]),
    ]
}
