// Creates or updates the Copado Function, Job Template and Job Step of the Story Verification Gate. Safe to rerun.
// Deploy the package first (it contains StoryVerificationSetup), then run:
//   sf apex run --file scripts/create-copado-records.apex --target-org <alias>
// or paste the next line into Execute Anonymous in the Developer Console.
StoryVerificationSetup.run();
