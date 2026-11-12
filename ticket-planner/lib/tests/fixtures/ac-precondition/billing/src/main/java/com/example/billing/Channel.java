package com.example.billing;

public enum Channel {
    EMAIL("e"),
    SMS("s");

    private final String code;

    Channel(String code) {
        this.code = code;
    }
}
