import Foundation

/// Internal pattern recognition engine for ProgressionAnalyzer.
enum ProgressionAnalyzer_PatternRecognition {

    static func recognizePattern(progression: [Chord], in key: MusicalKey) -> RecognizedPattern? {
        let numerals = progression.compactMap { RomanNumeral(chord: $0, in: key) }
        guard numerals.count >= 3 else { return nil }

        var exactMatch: RecognizedPattern? = nil

        for pattern in allPatterns {
            if numerals == pattern.numerals {
                return RecognizedPattern(pattern: pattern, matchType: .exact)
            }

            if exactMatch == nil && fuzzyMatch(numerals, against: pattern.numerals) {
                exactMatch = RecognizedPattern(pattern: pattern, matchType: .similar)
            }
        }

        return exactMatch
    }


    private static func fuzzyMatch(_ input: [RomanNumeral], against template: [RomanNumeral]) -> Bool {
        let maxLengthDiff = 1
        guard abs(input.count - template.count) <= maxLengthDiff else { return false }

        let matchCount = countMatches(input, against: template)
        let minMatches = 3
        let matchRate = Double(matchCount) / Double(max(input.count, template.count))

        return matchCount >= minMatches && matchRate >= 0.5
    }

    private static func countMatches(_ input: [RomanNumeral], against template: [RomanNumeral]) -> Int {
        var matches = 0
        var templateIndex = 0

        for inputNumeral in input {
            while templateIndex < template.count {
                let templateNumeral = template[templateIndex]
                templateIndex += 1

                if inputNumeral.degree == templateNumeral.degree && inputNumeral.accidental == templateNumeral.accidental {
                    matches += 1
                    break
                }
            }
        }

        return matches
    }

    private static let allPatterns: [ProgressionPattern] = [
        ProgressionPattern(
            name: "Pop Anthem",
            numerals: [
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .five, quality: .major),
                RomanNumeral(degree: .six, quality: .minor),
                RomanNumeral(degree: .four, quality: .major),
            ],
            description: "Iconic four-chord progression used in countless pop hits.",
            songExamples: [
                SongReference(songTitle: "Let It Be", artist: "The Beatles", detail: "1970"),
                SongReference(songTitle: "Don't Stop Believin'", artist: "Journey", detail: "1981"),
                SongReference(songTitle: "Zombie", artist: "The Cranberries", detail: "1994"),
            ]
        ),
        ProgressionPattern(
            name: "Sensitive/Emotional",
            numerals: [
                RomanNumeral(degree: .six, quality: .minor),
                RomanNumeral(degree: .four, quality: .major),
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .five, quality: .major),
            ],
            description: "Melancholic opening building to resolution.",
            songExamples: [
                SongReference(songTitle: "Wonderwall", artist: "Oasis", detail: "1996"),
                SongReference(songTitle: "Iris", artist: "Goo Goo Dolls", detail: "1998"),
            ]
        ),
        ProgressionPattern(
            name: "Classic Rock/Folk",
            numerals: [
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .four, quality: .major),
                RomanNumeral(degree: .five, quality: .major),
                RomanNumeral(degree: .one, quality: .major),
            ],
            description: "The I–IV–V–I progression, foundational in rock and folk.",
            songExamples: [
                SongReference(songTitle: "Wild Thing", artist: "The Troggs", detail: "1966"),
                SongReference(songTitle: "I Love Rock and Roll", artist: "Joan Jett", detail: "1982"),
            ]
        ),
        ProgressionPattern(
            name: "Jazz Standard",
            numerals: [
                RomanNumeral(degree: .two, quality: .minor),
                RomanNumeral(degree: .five, quality: .major),
                RomanNumeral(degree: .one, quality: .major),
            ],
            description: "The ii–V–I progression, essential in jazz.",
            songExamples: [
                SongReference(songTitle: "Autumn Leaves", artist: "Bill Evans", detail: "1962"),
                SongReference(songTitle: "Girl from Ipanema", artist: "João Gilberto", detail: "1964"),
            ]
        ),
        ProgressionPattern(
            name: "50s Doo-wop",
            numerals: [
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .six, quality: .minor),
                RomanNumeral(degree: .four, quality: .major),
                RomanNumeral(degree: .five, quality: .major),
            ],
            description: "Classic progression of the 1950s doo-wop era.",
            songExamples: [
                SongReference(songTitle: "Stand by Me", artist: "Ben E. King", detail: "1961"),
                SongReference(songTitle: "Earth Angel", artist: "The Penguins", detail: "1954"),
            ]
        ),
        ProgressionPattern(
            name: "Andalusian Cadence",
            numerals: [
                RomanNumeral(degree: .one, quality: .minor),
                RomanNumeral(degree: .seven, accidental: .flat, quality: .major),
                RomanNumeral(degree: .six, accidental: .flat, quality: .major),
                RomanNumeral(degree: .five, quality: .major),
            ],
            description: "Flamenco-inspired progression with minor key and borrowed chords.",
            songExamples: [
                SongReference(songTitle: "Entre Dos Aguas", artist: "Paco de Lucía", detail: "1973"),
            ]
        ),
        ProgressionPattern(
            name: "Mixolydian Rock",
            numerals: [
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .seven, accidental: .flat, quality: .major),
                RomanNumeral(degree: .four, quality: .major),
                RomanNumeral(degree: .one, quality: .major),
            ],
            description: "Rock progression using a major IV below the I.",
            songExamples: [
                SongReference(songTitle: "Sweet Home Chicago", artist: "Robert Johnson", detail: "1936"),
            ]
        ),
        ProgressionPattern(
            name: "Natural Minor Folk",
            numerals: [
                RomanNumeral(degree: .one, quality: .minor),
                RomanNumeral(degree: .four, quality: .minor),
                RomanNumeral(degree: .five, quality: .minor),
                RomanNumeral(degree: .one, quality: .minor),
            ],
            description: "Minor key progression using natural minor scale degrees.",
            songExamples: [
                SongReference(songTitle: "The House of the Rising Sun", artist: "The Animals", detail: "1964"),
            ]
        ),
        ProgressionPattern(
            name: "Building/Uplifting",
            numerals: [
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .four, quality: .major),
                RomanNumeral(degree: .six, quality: .minor),
                RomanNumeral(degree: .five, quality: .major),
            ],
            description: "Progression that builds energy toward resolution.",
            songExamples: [
                SongReference(songTitle: "Mr. Brightside", artist: "The Killers", detail: "2003"),
            ]
        ),
        ProgressionPattern(
            name: "Dreamy/Nostalgic",
            numerals: [
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .three, quality: .minor),
                RomanNumeral(degree: .six, quality: .minor),
                RomanNumeral(degree: .four, quality: .major),
            ],
            description: "Introspective progression evoking wistfulness.",
            songExamples: [
                SongReference(songTitle: "Daydream Believer", artist: "The Monkees", detail: "1967"),
            ]
        ),
        ProgressionPattern(
            name: "Epic/Cinematic",
            numerals: [
                RomanNumeral(degree: .one, quality: .minor),
                RomanNumeral(degree: .six, accidental: .flat, quality: .major),
                RomanNumeral(degree: .three, accidental: .flat, quality: .major),
                RomanNumeral(degree: .seven, accidental: .flat, quality: .major),
            ],
            description: "Dark, dramatic progression for orchestral or cinematic contexts.",
            songExamples: [
                SongReference(songTitle: "Requiem for a Dream", artist: "Clint Mansell", detail: "2000"),
            ]
        ),
        ProgressionPattern(
            name: "Jazz Turnaround",
            numerals: [
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .six, quality: .minor),
                RomanNumeral(degree: .two, quality: .minor),
                RomanNumeral(degree: .five, quality: .major),
            ],
            description: "Jazz progression designed to loop smoothly.",
            songExamples: [
                SongReference(songTitle: "All The Things You Are", artist: "Bill Evans", detail: "1939"),
            ]
        ),
        ProgressionPattern(
            name: "Plagal Pop",
            numerals: [
                RomanNumeral(degree: .four, quality: .major),
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .five, quality: .major),
                RomanNumeral(degree: .six, quality: .minor),
            ],
            description: "Modern pop variant of the plagal cadence.",
            songExamples: [
                SongReference(songTitle: "Good as Hell", artist: "Lizzo", detail: "2016"),
            ]
        ),
        ProgressionPattern(
            name: "Canon in D",
            numerals: [
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .five, quality: .major),
                RomanNumeral(degree: .six, quality: .minor),
                RomanNumeral(degree: .three, quality: .minor),
                RomanNumeral(degree: .four, quality: .major),
                RomanNumeral(degree: .one, quality: .major),
                RomanNumeral(degree: .four, quality: .major),
                RomanNumeral(degree: .five, quality: .major),
            ],
            description: "Pachelbel's canon, an eight-bar loop beloved in modern pop.",
            songExamples: [
                SongReference(songTitle: "Canon in D", artist: "Johann Pachelbel", detail: "1680"),
                SongReference(songTitle: "Graduation (Friends Forever)", artist: "Vitamin C", detail: "2000"),
            ]
        ),
        ProgressionPattern(
            name: "Phrygian Cadence",
            numerals: [
                RomanNumeral(degree: .four, quality: .minor),
                RomanNumeral(degree: .three, accidental: .flat, quality: .major),
                RomanNumeral(degree: .two, accidental: .flat, quality: .major),
                RomanNumeral(degree: .one, quality: .minor),
            ],
            description: "Spanish/classical progression with iv–♭III–♭II–i movement.",
            songExamples: [
                SongReference(songTitle: "Gymnopedie No. 1", artist: "Erik Satie", detail: "1888"),
            ]
        ),
    ]
}
