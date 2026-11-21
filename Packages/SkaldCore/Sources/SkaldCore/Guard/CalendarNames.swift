enum CalendarNames {
    static func contains(_ word: String, _ language: Language) -> Bool {
        names[language]!.contains(word.lowercased())
    }

    private static let names: [Language: Set<String>] = [
        .en: [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
            "november", "december",
        ],
        .nl: [
            "maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag", "zondag",
            "januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober",
            "november", "december",
        ],
        .fr: [
            "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
            "janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre",
            "novembre", "décembre",
        ],
    ]
}
