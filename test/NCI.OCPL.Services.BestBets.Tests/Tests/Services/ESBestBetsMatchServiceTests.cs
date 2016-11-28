using System.Collections.Generic;
using System.Net.Http;
using Microsoft.Extensions.Options;

using Xunit;
using Moq;

using Nest;
using Elasticsearch.Net;

using NCI.OCPL.Utils.Testing;

using NCI.OCPL.Services.BestBets.Services;
using NCI.OCPL.Services.BestBets.Tests.ESMatchTestData;
using System;
using Microsoft.Extensions.Logging.Testing;

namespace NCI.OCPL.Services.BestBets.Tests
{
    public class ESBestBetsMatchServiceTests
    {


        public static IEnumerable<object[]> GetMatchesData => new[] {
            // "pancoast" is a simple test as it only has 1 hit, 1 word, and 1 BB category.
            new object[] { 
                "pancoast", 
                "en", 
                new ESMatchConnection("pancoast"), 
                new string[] { "36012" } 
            },
            // "breast cancer" is more complicated, it has 1 hit, 2 words, and the BB category
            // it matches is on page 2.  It also has a ton of negations for breast.
            new object[] { 
                "breast cancer", 
                "en", 
                new ESMatchConnection("breastcancer"), 
                new string[] { "36408" } 
            },
            // "breast cancer treatment" is more complicated, it has 1 hit, 3 words, and no results for last page.
            // It also has a ton of negations for various combinations.
            new object[] {
                "breast cancer treatment",
                "en",
                new ESMatchConnection("breastcancertreatment"),
                new string[] { "36408" }
            },
            // "seer stat" is a negated exact match test.  SEER should not be returned
            new object[] {
                "seer stat",
                "en",
                new ESMatchConnection("seerstat"),
                new string[] { }
            },
            // "seer stat fact sheet" is a test to make sure the "seer stat" exact match is not hit because
            // we are not exactly matching the phrase "seet stat". Those search terms also match seer.
            new object[] {
                "seer stat fact sheet",
                "en",
                new ESMatchConnection("seerstatfactsheet"),
                new string[] { "36681" }
            },
        };


        [Theory, MemberData("GetMatchesData")]
        public void GetMatches_Normal(
            string searchTerm, 
            string lang, 
            ESMatchConnection connection, 
            string[] expectedCategories
        )
        {
            //Use real ES client, with mocked connection.

            //While this has a URI, it does not matter, an InMemoryConnection never requests
            //from the server.
            var pool = new SingleNodeConnectionPool(new Uri("http://localhost:9200"));

            var connectionSettings = new ConnectionSettings(pool, connection);            
            
            IElasticClient client = new ElasticClient(connectionSettings);

            ESBestBetsMatchService service = new ESBestBetsMatchService(client, new NullLogger<ESBestBetsMatchService>());

            string[] actualMatches = service.GetMatches(lang, searchTerm);

            Assert.Equal(expectedCategories, actualMatches);
        }



    }
}