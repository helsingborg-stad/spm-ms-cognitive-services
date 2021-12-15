# MSCognitiveServices
Package that supplies a number of Microsoft services and implements the TTSService and TextTranslationService protocols. 

## MSTextTranslator
The package includes an implementation of the Microsoft Text Transalator API.
> Get aquainted with the api here: https://docs.microsoft.com/en-us/azure/cognitive-services/translator

To get started you need to create a translator resource in azure and obtain an acecss key and region of the service.

After that you're ready to get started. Begin by setting up your translator

```swift
let translator = MSTextTranslator(config: .init(key:"your key", region:"your service region"))
```

There's a number of translation methods available depending on your needs. You can supply an array of strings, a dictionary of keys and values or a single string. You can also translate multiple langauges at one time.

### Translate using swift concurrency
```swift
let texts = ["my_string": "My untranslated text"]
do {
    let table = try await translator.translateAsync(texts, from: "en", to: ["sv","fr"])
    print(table.value(forKey: "my_string", in: "sv"))
} catch {
    debugPrint(error)
}
```

### Translate using combine publisher
```swift
let texts = ["my_string": "My untranslated text"]
translator.translate(texts, from: "en", to: ["sv","fr"]).sink { [weak self] compl in
    if case let .failure(error) = compl {
        debugPrint(error)
    }
} receiveValue: { [weak self] table in
    print(table.value(forKey: "my_string", in: "sv"))
}.store(in: &cancellables)
```

### TextTranslationTable
The TextTranslationTable is a structure used to store and return translated values. The structure can be used to reduce the number of calls made to the backend by ensuring that a value isn't translated more than once. Once one or more values has been translated you can store the returned table for later use. You don't have to check if the table contains a string before you translate, the framework will do that for you.

```swift
class Translator : ObservableObject {
    let service = MSTextTranslator(config: .init(key:"your key", region:"your service region"))
    var translations = TextTranslationTable()
    init () {
        service.logger.publisher.sink { e in
            print(e.description)
        }
    }
    func translate(_ texts:[String:String]) {
        do {
            translations = try await service.translateAsync(texts, from: "en", to: ["sv","fr"], storeIn: translations)
        } catch {
            debugPrint(error)
        }
    }
    func string(for key:String, in language:String) -> String? {
        return translations.value(forKey: key, in: language) 
    }
}
```

### Use in combination with Dragoman
If you're creating an app and you're making use of native localization, you might want to take a look at the Dragoman package and how the MSTextTranslator can be used to automatically write and read translated texts to strings files.

More information can be found at https://github.com/helsingborg-stad/spm-dragoman

### Limitations
There are a number of limitations to the api depending on your subscription level. The framework them all into account with one exception and that's number of requests per minute. You can read more about the limitations here: https://docs.microsoft.com/en-us/azure/cognitive-services/translator/request-limits

## Microsoft static framework
> This section is directed to the developer of this package

Microsoft has yet to release it's own SPM package. Therefor this package includes a binary target declaration of their static framework.

In case the framework is updated the developer of this repo must make sure to add the new zip-reference and change the checksum.

Once you've obtained the zip url(have a look at the current url and just change the version number, it should work) you need to add it to the url to the `Package.swift` file.

Once that's done you need to download the zip file to your computer and run `shasum -a 256 [FILENAME].zip`. The result of the command should go into the `checksum` parameter of the `Package.swift` file

## TODO

- [ ] list available services
- [ ] add download support (ie offline support) to the MSTTS 
- [ ] finish the speech recognizer implementation using the STTService protocol
- [ ] create a STTTranslationService protocol similar to the SSTService protocol and implement it to the MSSpeechTranslator
- [ ] code-documentation
- [ ] write tests
- [ ] complete package documentation

