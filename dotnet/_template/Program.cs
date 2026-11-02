using Azure.Identity;
using Microsoft.Extensions.Configuration;

var config = new ConfigurationBuilder()
    .AddJsonFile("appsettings.json", optional: true)
    .AddJsonFile("appsettings.Development.json", optional: true)
    .AddUserSecrets<Program>(optional: true)
    .AddEnvironmentVariables()
    .Build();

var endpoint = config["Azure:Endpoint"]
    ?? throw new InvalidOperationException("Set Azure:Endpoint in appsettings or user-secrets.");

var credential = new DefaultAzureCredential();

Console.WriteLine($"Endpoint: {endpoint}");
// TODO: create your Azure client here using `endpoint` and `credential`.
