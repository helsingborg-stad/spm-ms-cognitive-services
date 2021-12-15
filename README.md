# MSCognitiveServices
Package that supplies a number of Microsoft services and implements the TTSService and TextTranslationService protocols. 

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

