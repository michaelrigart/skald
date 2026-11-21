public enum FunctionWords {
    public static func contains(_ word: String, _ language: Language) -> Bool {
        words[language]!.contains(word.lowercased())
    }

    static func isAuxiliary(_ word: String, _ language: Language) -> Bool {
        auxiliaries[language]!.contains(word.lowercased())
    }

    static func isPreposition(_ word: String, _ language: Language) -> Bool {
        prepositions[language]!.contains(word.lowercased())
    }

    private static let auxiliaries: [Language: Set<String>] = [
        .en: [
            "have", "has", "had", "having", "haven", "hasn", "hadn",
            "am", "is", "are", "was", "were", "be", "been", "being", "isn", "aren", "wasn", "weren",
            "do", "does", "did", "don", "doesn", "didn",
        ],
        .nl: [
            "heb", "hebt", "heeft", "hebben", "had", "hadden", "gehad",
            "ben", "bent", "is", "zijn", "was", "waren", "geweest",
            "word", "wordt", "worden", "werd", "werden", "geworden",
            "zal", "zult", "zul", "zullen", "zou", "zouden",
        ],
        .fr: [
            "ai", "as", "a", "avons", "avez", "ont", "avais", "avait", "avions", "aviez", "avaient", "eu",
            "aurai", "auras", "aura", "aurons", "aurez", "auront", "aurais", "aurait", "aurions", "auriez",
            "auraient", "ait", "aient",
            "suis", "es", "est", "sommes", "êtes", "sont", "étais", "était", "étions", "étiez", "étaient",
            "été", "étant", "serai", "seras", "sera", "serons", "serez", "seront", "serais", "serait",
            "serions", "seriez", "seraient", "soit", "soient", "sois",
        ],
    ]

    private static let prepositions: [Language: Set<String>] = [
        .en: [
            "of", "in", "on", "at", "by", "for", "with", "about", "against", "between", "into", "through",
            "during", "before", "after", "above", "below", "to", "from", "over", "under", "per", "via",
            "without", "within", "upon", "onto", "across", "behind", "beyond", "near",
        ],
        .nl: [
            "in", "op", "aan", "van", "voor", "met", "door", "naar", "uit", "bij", "over", "onder", "tegen",
            "na", "om", "zonder", "tussen", "tijdens", "binnen", "buiten", "naast", "achter", "boven", "langs",
            "tot",
        ],
        .fr: [
            "à", "dans", "sur", "sous", "par", "pour", "avec", "sans", "chez", "vers", "entre", "contre",
            "depuis", "pendant", "avant", "après", "devant", "derrière",
        ],
    ]

    private static let pronounsArticlesAndConjunctions: [Language: Set<String>] = [
        .en: [
            "a", "an", "the", "this", "that", "these", "those",
            "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves", "you", "your", "yours",
            "yourself", "he", "him", "his", "himself", "she", "her", "hers", "herself", "it", "its", "itself",
            "they", "them", "their", "theirs", "themselves", "who", "whom", "whose", "which", "what",
            "and", "or", "but", "nor", "if", "because", "although", "though", "while", "whereas", "than", "as",
            "s", "ve", "re", "m", "d",
        ],
        .nl: [
            "de", "het", "een", "'t", "'n",
            "ik", "mij", "me", "mijn", "m'n", "jij", "je", "jou", "jouw", "u", "uw", "hij", "hem", "zij", "ze",
            "haar", "hun", "hen", "wij", "we", "ons", "onze", "jullie", "men", "zich", "zelf",
            "die", "dat", "deze", "dit", "wie", "wat", "welk", "welke",
            "en", "of", "maar", "want", "dus", "dan", "als", "omdat", "hoewel", "terwijl", "zodat", "indien",
            "noch", "doch",
        ],
        .fr: [
            "le", "la", "les", "l", "un", "une", "des", "du", "de", "d", "au", "aux",
            "je", "j", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "me", "m", "te", "t", "se",
            "s", "lui", "leur", "leurs", "moi", "toi", "soi", "eux", "y", "en",
            "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "notre", "nos", "votre", "vos",
            "ce", "c", "cet", "cette", "ces", "ceci", "cela", "ça", "celui", "celle", "ceux", "celles",
            "qui", "que", "qu", "quoi", "dont", "où", "lequel", "laquelle", "lesquels", "lesquelles",
            "ou", "et", "mais", "donc", "or", "ni", "car", "si", "comme", "quand", "lorsque", "puisque", "parce",
        ],
    ]

    private static let words: [Language: Set<String>] = Dictionary(uniqueKeysWithValues: Language.allCases.map {
        ($0, auxiliaries[$0]!.union(prepositions[$0]!).union(pronounsArticlesAndConjunctions[$0]!))
    })
}
