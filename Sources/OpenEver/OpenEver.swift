import ArgumentParser

@main
struct OpenEver: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "openever",
        abstract: "Everscale command-line tools.",
        discussion: "Use --config before or after subcommands. Run 'openever help config' to manage configuration and 'openever help liteclient' for connection options.",
        version: BuildVersion.value,
        subcommands: [ConfigCommand.self, LiteClientCommand.self, WalletCommand.self]
    )
    @OptionGroup var configurationOptions: ConfigurationOptions
}

struct LiteClientCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "liteclient",
        abstract: "Query an ADNL lite server and submit serialized messages.",
        discussion: "Connection options may appear after liteclient or after its operation. Results are JSON on stdout, except make-vm-params which prints base64; errors go to stderr.",
        subcommands: [AccountStateCommand.self, RunMethodCommand.self,
                      SendMessageCommand.self, TransactionCommand.self,
                      TransactionsCommand.self, LookupBlockCommand.self, QueryCommand.self,
                      MakeVMParamsCommand.self, ParseVMResultCommand.self]
    )
    @OptionGroup var connection: ConnectionOptions
}
